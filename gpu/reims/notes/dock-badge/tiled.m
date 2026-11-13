// tiled.m: the mipmapped texture over a buffer that WindowServer makes
// (newTiledTextureWithDescriptor:offset:bytesPerRow:), its small levels filled in several ways,
// each level then read back through a blit and through getBytes.
//
//   tiled MODE [SIZE]     MODE: replace | replace-late | generate | blit | none
//
// Level 0 is white in the buffer. Level n is written as the byte 0x10 * n + 0x0f in every
// channel, so a level that reads 00 was lost.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

@interface NSObject (TiledSPI)
- (id<MTLTexture>)newTiledTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)o bytesPerRow:(NSUInteger)p;
@end

static void commit(id<MTLCommandBuffer> cb) { [cb commit]; [cb waitUntilCompleted]; }

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"replace";
        NSUInteger size = argc > 2 ? atoi(argv[2]) : 64;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSUInteger pitch = size * 4;
        id<MTLBuffer> buf = [dev newBufferWithLength:pitch * size options:MTLResourceStorageModeShared];
        memset(buf.contents, 0xff, buf.length);

        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:size height:size mipmapped:YES];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeManaged;
        id<MTLTexture> tex = nil;
        if ([mode hasPrefix:@"plain"]) {
            tex = [dev newTextureWithDescriptor:d];
            mode = [mode substringFromIndex:6];
            NSMutableData *w = [NSMutableData dataWithLength:pitch * size];
            memset(w.mutableBytes, 0xff, w.length);
            [tex replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0 withBytes:w.bytes bytesPerRow:pitch];
        } else {
            tex = [(id)buf newTiledTextureWithDescriptor:d offset:0 bytesPerRow:pitch];
        }
        if (tex == nil) { printf("no texture\n"); return 1; }
        NSUInteger levels = tex.mipmapLevelCount;
        printf("%s: %lux%lu, %lu levels, storage %lu, class %s\n", mode.UTF8String, (unsigned long)size,
               (unsigned long)size, (unsigned long)levels, (unsigned long)tex.storageMode,
               object_getClassName(tex));

        id<MTLBuffer> out = [dev newBufferWithLength:pitch * size options:MTLResourceStorageModeShared];

        void (^touch)(void) = ^{   // a first GPU use: level 0 read by a blit
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(size, size, 1) toBuffer:out destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:pitch * size];
            [b endEncoding];
            commit(cb);
        };
        void (^replace)(void) = ^{
            for (NSUInteger l = 1; l < levels; l++) {
                NSUInteger s = MAX(size >> l, 1);
                NSMutableData *px = [NSMutableData dataWithLength:s * s * 4];
                memset(px.mutableBytes, 0x10 * l + 0x0f, px.length);
                [tex replaceRegion:MTLRegionMake2D(0, 0, s, s) mipmapLevel:l withBytes:px.bytes bytesPerRow:s * 4];
            }
        };

        if ([mode isEqual:@"replace"]) {
            replace();
        } else if ([mode isEqual:@"replace-late"]) {
            touch();
            replace();
        } else if ([mode isEqual:@"generate"]) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b generateMipmapsForTexture:tex];
            [b endEncoding];
            commit(cb);
        } else if ([mode isEqual:@"blit"]) {
            id<MTLBuffer> src = [dev newBufferWithLength:pitch * size options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            NSUInteger at = 0;
            for (NSUInteger l = 1; l < levels; l++) {
                NSUInteger s = MAX(size >> l, 1);
                memset((uint8_t *)src.contents + at, 0x10 * l + 0x0f, s * s * 4);
                [b copyFromBuffer:src sourceOffset:at sourceBytesPerRow:s * 4 sourceBytesPerImage:s * s * 4
                       sourceSize:MTLSizeMake(s, s, 1) toTexture:tex destinationSlice:0 destinationLevel:l
                destinationOrigin:MTLOriginMake(0, 0, 0)];
                at += (s * s * 4 + 255) & ~(NSUInteger)255;
            }
            [b endEncoding];
            commit(cb);
        }

        printf("level  gpu(blit)  cpu(getBytes)  wanted\n");
        for (NSUInteger l = 0; l < levels; l++) {
            NSUInteger s = MAX(size >> l, 1);
            memset(out.contents, 0xaa, out.length);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:tex sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(s, s, 1) toBuffer:out destinationOffset:0
        destinationBytesPerRow:s * 4 destinationBytesPerImage:s * s * 4];
            [b endEncoding];
            commit(cb);
            uint8_t g = ((uint8_t *)out.contents)[(s * s / 2) * 4 % (s * s * 4)];
            uint8_t cpu[4] = {0xbb, 0xbb, 0xbb, 0xbb};
            [tex getBytes:cpu bytesPerRow:4 fromRegion:MTLRegionMake2D(s / 2, s / 2, 1, 1) mipmapLevel:l];
            printf("%5lu  %02x         %02x             %s\n", (unsigned long)l, g, cpu[0],
                   l == 0 ? "ff" : [mode isEqual:@"generate"] ? "ff" : [mode isEqual:@"none"] ? "?" :
                   [[NSString stringWithFormat:@"%02x", (unsigned)(0x10 * l + 0x0f)] UTF8String]);
        }
    }
    return 0;
}
