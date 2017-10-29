@import simd;
@import MetalKit;

#import "DebugLogging.h"
#import "iTermTextureArray.h"
#import "iTermMetalDriver.h"
#import "iTermBackgroundImageRenderer.h"
#import "iTermBackgroundColorRenderer.h"
#import "iTermBadgeRenderer.h"
#import "iTermBroadcastStripesRenderer.h"
#import "iTermCursorGuideRenderer.h"
#import "iTermCursorRenderer.h"
#import "iTermMetalFrameData.h"
#import "iTermMarkRenderer.h"
#import "iTermMetalRowData.h"
#import "iTermPreciseTimer.h"
#import "iTermTextRenderer.h"
#import "iTermTextureMap.h"

#import "iTermShaderTypes.h"

static const NSInteger iTermMetalDriverMaximumNumberOfFramesInFlight = 3;

@implementation iTermMetalCursorInfo
@end

@interface iTermMetalDriver()
// This indicates if a draw call was made while busy. When we stop being busy
// and this is set, then we must schedule another draw.
@property (atomic) BOOL needsDraw;
@end

@implementation iTermMetalDriver {
    iTermBackgroundImageRenderer *_backgroundImageRenderer;
    iTermBackgroundColorRenderer *_backgroundColorRenderer;
    iTermTextRenderer *_textRenderer;
    iTermMarkRenderer *_markRenderer;
    iTermBadgeRenderer *_badgeRenderer;
    iTermBroadcastStripesRenderer *_broadcastStripesRenderer;
    iTermCursorGuideRenderer *_cursorGuideRenderer;
    iTermCursorRenderer *_underlineCursorRenderer;
    iTermCursorRenderer *_barCursorRenderer;
    iTermCursorRenderer *_blockCursorRenderer;
    iTermCursorRenderer *_frameCursorRenderer;
    iTermCopyModeCursorRenderer *_copyModeCursorRenderer;

    // The command Queue from which we'll obtain command buffers
    id<MTLCommandQueue> _commandQueue;

    // The current size of our view so we can use this in our render pipeline
    vector_uint2 _viewportSize;
    CGSize _cellSize;
//    int _iteration;
    int _rows;
    int _columns;
    BOOL _sizeChanged;
    CGFloat _scale;

    dispatch_queue_t _queue;

    iTermMetalFrameDataStatsBundle _stats;
    int _dropped;
    int _total;

    // @synchronized(self)
    int _framesInFlight;
    NSMutableArray *_currentFrames;
    NSTimeInterval _startTime;
}

- (nullable instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView {
    self = [super init];
    if (self) {
        _startTime = [NSDate timeIntervalSinceReferenceDate];
        _backgroundImageRenderer = [[iTermBackgroundImageRenderer alloc] initWithDevice:mtkView.device];
        _textRenderer = [[iTermTextRenderer alloc] initWithDevice:mtkView.device];
        _backgroundColorRenderer = [[iTermBackgroundColorRenderer alloc] initWithDevice:mtkView.device];
        _markRenderer = [[iTermMarkRenderer alloc] initWithDevice:mtkView.device];
        _badgeRenderer = [[iTermBadgeRenderer alloc] initWithDevice:mtkView.device];
        _broadcastStripesRenderer = [[iTermBroadcastStripesRenderer alloc] initWithDevice:mtkView.device];
        _cursorGuideRenderer = [[iTermCursorGuideRenderer alloc] initWithDevice:mtkView.device];
        _underlineCursorRenderer = [iTermCursorRenderer newUnderlineCursorRendererWithDevice:mtkView.device];
        _barCursorRenderer = [iTermCursorRenderer newBarCursorRendererWithDevice:mtkView.device];
        _blockCursorRenderer = [iTermCursorRenderer newBlockCursorRendererWithDevice:mtkView.device];
        _frameCursorRenderer = [iTermCursorRenderer newFrameCursorRendererWithDevice:mtkView.device];
        _copyModeCursorRenderer = [iTermCursorRenderer newCopyModeCursorRendererWithDevice:mtkView.device];
        _commandQueue = [mtkView.device newCommandQueue];
        _queue = dispatch_queue_create("com.iterm2.metalDriver", NULL);
        _currentFrames = [NSMutableArray array];

        iTermMetalFrameDataStatsBundleInitialize(&_stats);
    }

    return self;
}

#pragma mark - APIs

- (void)setCellSize:(CGSize)cellSize gridSize:(VT100GridSize)gridSize scale:(CGFloat)scale {
    scale = MAX(1, scale);
    cellSize.width *= scale;
    cellSize.height *= scale;
    dispatch_async(_queue, ^{
        if (scale == 0) {
            NSLog(@"Warning: scale is 0");
        }
        NSLog(@"Cell size is now %@x%@, grid size is now %@x%@", @(cellSize.width), @(cellSize.height), @(gridSize.width), @(gridSize.height));
        _sizeChanged = YES;
        _cellSize = cellSize;
        _rows = MAX(1, gridSize.height);
        _columns = MAX(1, gridSize.width);
        _scale = scale;
    });
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    dispatch_async(_queue, ^{
        // Save the size of the drawable as we'll pass these
        //   values to our vertex shader when we draw
        _viewportSize.x = size.width;
        _viewportSize.y = size.height;
    });
}

// Called whenever the view needs to render a frame
- (void)drawInMTKView:(nonnull MTKView *)view {
    if (_rows == 0 || _columns == 0) {
        DLog(@"  abort: uninitialized");
        [self scheduleDrawIfNeededInView:view];
        return;
    }

    _total++;
    if (_total % 60 == 0) {
        @synchronized (self) {
            NSLog(@"fps=%f (%d in flight)", (_total - _dropped) / ([NSDate timeIntervalSinceReferenceDate] - _startTime), (int)_framesInFlight);
            NSLog(@"%@", _currentFrames);
        }
    }
    BOOL shouldDrop;
    @synchronized(self) {
        shouldDrop = (_framesInFlight == iTermMetalDriverMaximumNumberOfFramesInFlight);
        if (!shouldDrop) {
            _framesInFlight++;
        }
    }
    if (shouldDrop) {
        NSLog(@"  abort: busy (dropped %@%%, number in flight: %d)", @((_dropped * 100)/_total), (int)_framesInFlight);
        _dropped++;
        self.needsDraw = YES;
        return;
    }

    iTermMetalFrameData *frameData = [self newFrameData];

    @synchronized(self) {
        [_currentFrames addObject:frameData];
    }

    [frameData loadFromView:view];

    dispatch_async(_queue, ^{
        [self prepareRenderersWithFrameData:frameData view:view];
    });
}

#pragma mark - Drawing
// Called on the main queue
- (iTermMetalFrameData *)newFrameData {
    iTermMetalFrameData *frameData = [[iTermMetalFrameData alloc] init];
    frameData.perFrameState = [_dataSource metalDriverWillBeginDrawingFrame];
    frameData.transientStates = [NSMutableDictionary dictionary];
    frameData.rows = [NSMutableArray array];
    frameData.gridSize = VT100GridSizeMake(_columns, _rows);
    frameData.scale = _scale;
    return frameData;
}

- (void)prepareRenderersWithFrameData:(iTermMetalFrameData *)frameData
                                 view:(nonnull MTKView *)view {
    dispatch_group_t group = dispatch_group_create();
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];

    [frameData prepareWithBlock:^{
        [commandBuffer enqueue];
        commandBuffer.label = @"Draw Terminal";
        [self.nonCellRenderers enumerateObjectsUsingBlock:^(id<iTermMetalRenderer>  _Nonnull renderer, NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_group_enter(group);
            [renderer createTransientStateForViewportSize:_viewportSize
                                                    scale:frameData.scale
                                            commandBuffer:commandBuffer
                                               completion:^(__kindof iTermMetalRendererTransientState * _Nonnull tState) {
                                                   if (tState) {
                                                       frameData.transientStates[NSStringFromClass(renderer.class)] = tState;
                                                       [self updateRenderer:renderer
                                                                      state:tState
                                                              perFrameState:frameData.perFrameState];
                                                   }
                                                   dispatch_group_leave(group);
                                               }];
        }];
        VT100GridSize gridSize = frameData.gridSize;
        [self.cellRenderers enumerateObjectsUsingBlock:^(id<iTermMetalCellRenderer>  _Nonnull renderer, NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_group_enter(group);
            [renderer createTransientStateForViewportSize:_viewportSize
                                                    scale:frameData.scale
                                                 cellSize:_cellSize
                                                 gridSize:gridSize
                                            commandBuffer:commandBuffer
                                               completion:^(__kindof iTermMetalCellRendererTransientState * _Nonnull tState) {
                                                   if (tState) {
                                                       frameData.transientStates[NSStringFromClass([renderer class])] = tState;
                                                       [self updateRenderer:renderer
                                                                      state:tState
                                                              perFrameState:frameData.perFrameState];
                                                   }
                                                   dispatch_group_leave(group);
                                               }];
        }];

        // Renderers may not yet have transient state
        for (int y = 0; y < frameData.gridSize.height; y++) {
            iTermMetalRowData *rowData = [[iTermMetalRowData alloc] init];
            [frameData.rows addObject:rowData];
            rowData.y = y;
            rowData.keysData = [NSMutableData dataWithLength:sizeof(iTermMetalGlyphKey) * _columns];
            rowData.attributesData = [NSMutableData dataWithLength:sizeof(iTermMetalGlyphAttributes) * _columns];
            rowData.backgroundColorData = [NSMutableData dataWithLength:sizeof(vector_float4) * _columns];
            iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)rowData.keysData.mutableBytes;
            [frameData.perFrameState metalGetGlyphKeys:glyphKeys
                                            attributes:rowData.attributesData.mutableBytes
                                            background:rowData.backgroundColorData.mutableBytes
                                                   row:y
                                                 width:_columns];
        }
    }];

    [frameData waitForUpdatesToFinishOnGroup:group
                                     onQueue:_queue
                                    finalize:^{
                                        // All transient states are initialized
                                        [self finalizeRenderersWithFrameData:frameData];
                                    }
                                      render:^{
                                          [self reallyDrawInView:view frameData:frameData commandBuffer:commandBuffer];
                                      }];
}

// Called when all renderers have transient state
- (void)finalizeRenderersWithFrameData:(iTermMetalFrameData *)frameData {
    // TODO: call setMarkStyle:row: for each mark
    iTermTextRendererTransientState *textState =
    frameData.transientStates[NSStringFromClass([_textRenderer class])];
    iTermBackgroundColorRendererTransientState *backgroundState =
    frameData.transientStates[NSStringFromClass([_backgroundColorRenderer class])];
    CGSize cellSize = textState.cellSize;
    CGFloat scale = frameData.scale;

    iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];
    if (!cursorInfo.frameOnly && cursorInfo.cursorVisible && cursorInfo.shouldDrawText) {
        iTermMetalRowData *rowWithCursor = frameData.rows[cursorInfo.coord.y];
        iTermMetalGlyphAttributes *glyphAttributes = (iTermMetalGlyphAttributes *)rowWithCursor.attributesData.mutableBytes;
        glyphAttributes[cursorInfo.coord.x].foregroundColor = cursorInfo.textColor;
        glyphAttributes[cursorInfo.coord.x].backgroundColor = simd_make_float4(cursorInfo.cursorColor.redComponent,
                                                                               cursorInfo.cursorColor.greenComponent,
                                                                               cursorInfo.cursorColor.blueComponent,
                                                                               1);
    }
    [frameData.rows enumerateObjectsUsingBlock:^(iTermMetalRowData * _Nonnull rowData, NSUInteger idx, BOOL * _Nonnull stop) {
        iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)rowData.keysData.mutableBytes;
        [textState setGlyphKeysData:rowData.keysData
                     attributesData:rowData.attributesData
                                row:rowData.y
                           creation:^NSImage *(int x) {
                               return [frameData.perFrameState metalImageForGlyphKey:&glyphKeys[x]
                                                                                size:cellSize
                                                                               scale:scale];
                           }];
        [backgroundState setColorData:rowData.backgroundColorData
                                  row:rowData.y
                                width:frameData.gridSize.width];
    }];

    // Tell the text state that it's done getting row data.
    [textState willDraw];
}

- (void)drawCellRenderer:(id<iTermMetalCellRenderer>)renderer
               frameData:(iTermMetalFrameData *)frameData
           renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder {
    NSString *className = NSStringFromClass([renderer class]);
    iTermMetalCellRendererTransientState *state = frameData.transientStates[className];
    assert(state);
    [renderer drawWithRenderEncoder:renderEncoder transientState:state];
}

- (void)reallyDrawInView:(MTKView *)view
               frameData:(iTermMetalFrameData *)frameData
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    DLog(@"  Really drawing");

    MTLRenderPassDescriptor *renderPassDescriptor = frameData.renderPassDescriptor;
    if (renderPassDescriptor != nil) {
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        renderEncoder.label = @"Render Terminal";
        frameData.drawable.texture.label = @"Drawable";

        // Set the region of the drawable to which we'll draw.
        MTLViewport viewport = {
            -(double)_viewportSize.x,
            0.0,
            _viewportSize.x * 2,
            _viewportSize.y * 2,
            -1.0,
            1.0
        };
        [renderEncoder setViewport:viewport];

        //        [_backgroundImageRenderer drawWithRenderEncoder:renderEncoder];
        [self drawCellRenderer:_backgroundColorRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder];
        //        [_broadcastStripesRenderer drawWithRenderEncoder:renderEncoder];
        //        [_badgeRenderer drawWithRenderEncoder:renderEncoder];
        //        [_cursorGuideRenderer drawWithRenderEncoder:renderEncoder];
        //

        iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];
        if (cursorInfo.cursorVisible) {
            switch (cursorInfo.type) {
                case CURSOR_UNDERLINE:
                    [self drawCellRenderer:_underlineCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder];
                    break;
                case CURSOR_BOX:
                    if (cursorInfo.frameOnly) {
                        [self drawCellRenderer:_frameCursorRenderer
                                     frameData:frameData
                                 renderEncoder:renderEncoder];
                    } else {
                        [self drawCellRenderer:_blockCursorRenderer
                                     frameData:frameData
                                 renderEncoder:renderEncoder];
                    }
                    break;
                case CURSOR_VERTICAL:
                    [self drawCellRenderer:_barCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder];
                    break;
                case CURSOR_DEFAULT:
                    break;
            }
        }

        //        [_copyModeCursorRenderer drawWithRenderEncoder:renderEncoder];

        [self drawCellRenderer:_textRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder];

        //        [_markRenderer drawWithRenderEncoder:renderEncoder];

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:frameData.drawable];

        int counter;
        static int nextCounter;
        counter = nextCounter++;
        __block BOOL completed = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), _queue, ^{
            if (!completed) {
                frameData.status = @"wedge detected";
                NSLog(@"WEDGED STATE DETECTED! %@", frameData);
                completed = YES;
                [self complete:frameData];
            }
         });

        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
            frameData.status = @"completion handler, waiting for dispatch";
            dispatch_async(_queue, ^{
                if (!completed) {
                    completed = YES;
                    [self complete:frameData];
                    [self scheduleDrawIfNeededInView:view];
                }
            });
        }];

        [commandBuffer commit];
    } else {
        frameData.status = @"failed to get a render pass descriptor";
        [commandBuffer commit];
        [self complete:frameData];
    }
}

- (void)complete:(iTermMetalFrameData *)frameData {
    [frameData didComplete];

    DLog(@"  Completed");

    // Unlock indices and free up the stage texture.
    iTermTextRendererTransientState *textState =
        frameData.transientStates[NSStringFromClass([_textRenderer class])];
    [textState didComplete];

    [frameData addStatsTo:&_stats];
    iTermPreciseTimerStats stats[] = {
        _stats.mainThreadStats,
        _stats.getCurrentDrawableStats,
        _stats.getCurrentRenderPassDescriptorStats,
        _stats.dispatchStats,
        _stats.prepareStats,
        _stats.waitForGroup,
        _stats.finalizeStats,
        _stats.metalSetupStats,
        _stats.renderingStats,
        _stats.endToEnd
    };
    iTermPreciseTimerPeriodicLog(stats, sizeof(stats) / sizeof(*stats), 1, YES);

    @synchronized(self) {
        _framesInFlight--;
        @synchronized(self) {
            frameData.status = @"retired";
            [_currentFrames removeObject:frameData];
        }
    }
}

#pragma mark - Updating

- (void)updateRenderer:(id)renderer
                 state:(iTermMetalRendererTransientState *)tState
         perFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    if (renderer == _backgroundImageRenderer) {
        [self updateBackgroundImageRendererWithPerFrameState:perFrameState];
    } else if (renderer == _backgroundColorRenderer ||
               renderer == _textRenderer ||
               renderer == _markRenderer ||
               renderer == _broadcastStripesRenderer) {
        // Nothing to do here
    } else if (renderer == _badgeRenderer) {
        [self updateBadgeRendererWithPerFrameState:perFrameState];
    } else if (renderer == _cursorGuideRenderer) {
        [self updateCursorGuideRendererWithPerFrameState:perFrameState];
    } else if (renderer == _underlineCursorRenderer ||
               renderer == _barCursorRenderer ||
               renderer == _blockCursorRenderer ||
               renderer == _frameCursorRenderer) {
        [self updateCursorRendererWithPerFrameState:perFrameState];
    } else if (renderer == _copyModeCursorRenderer) {
        [self updateCopyModeCursorRendererWithPerFrameState:perFrameState];
    }
}

- (void)updateBackgroundImageRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO: Change the image if needed
}

- (void)updateBadgeRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO: call setBadgeImage: if needed
}

- (void)updateCursorGuideRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO:
    // [_cursorGuideRenderer setRow:_dataSource.cursorGuideRow];
    // [_cursorGuideRenderer setColor:_dataSource.cursorGuideColor];
}

- (void)updateCursorRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    iTermMetalCursorInfo *cursorInfo = [perFrameState metalDriverCursorInfo];
    if (cursorInfo.cursorVisible) {
        switch (cursorInfo.type) {
            case CURSOR_UNDERLINE:
                [_underlineCursorRenderer setCoord:cursorInfo.coord];
                [_underlineCursorRenderer setColor:cursorInfo.cursorColor];
                break;
            case CURSOR_BOX:
                [_blockCursorRenderer setCoord:cursorInfo.coord];
                [_blockCursorRenderer setColor:cursorInfo.cursorColor];
                [_frameCursorRenderer setCoord:cursorInfo.coord];
                [_frameCursorRenderer setColor:cursorInfo.cursorColor];
                break;
            case CURSOR_VERTICAL:
                [_barCursorRenderer setCoord:cursorInfo.coord];
                [_barCursorRenderer setColor:cursorInfo.cursorColor];
                break;
            case CURSOR_DEFAULT:
                break;
        }
    }
}

- (void)updateCopyModeCursorRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO
    // setCoord, setSelecting:
}

#pragma mark - Helpers

- (NSArray<id<iTermMetalCellRenderer>> *)cellRenderers {
    return @[ _textRenderer,
              _backgroundColorRenderer,
              _markRenderer,
              _cursorGuideRenderer,
              _underlineCursorRenderer,
              _barCursorRenderer,
              _blockCursorRenderer,
              _frameCursorRenderer,
              _copyModeCursorRenderer ];
}

- (NSArray<id<iTermMetalRenderer>> *)nonCellRenderers {
    return @[ _backgroundImageRenderer,
              _badgeRenderer,
              _broadcastStripesRenderer ];
}

- (void)scheduleDrawIfNeededInView:(MTKView *)view {
    if (self.needsDraw) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.needsDraw) {
                self.needsDraw = NO;
                [view setNeedsDisplay:YES];
            }
        });
    }
}

@end

