#import "MSLVSOCK.h"

@interface MSLVSOCK ()
@property (strong, nullable) VZVirtioSocketDevice *socketDevice;
@end

@implementation MSLVSOCK

- (instancetype)initWithConfiguration:(VZVirtualMachineConfiguration *)config {
    self = [super init];
    if (self) {
        VZVirtioSocketDeviceConfiguration *sockConfig = [[VZVirtioSocketDeviceConfiguration alloc] init];
        config.socketDevices = @[sockConfig];
    }
    return self;
}

- (void)setVM:(VZVirtualMachine *)vm {
    for (VZSocketDevice *dev in vm.socketDevices) {
        if ([dev isKindOfClass:[VZVirtioSocketDevice class]]) {
            self.socketDevice = (VZVirtioSocketDevice *)dev;
            return;
        }
    }
}

- (void)connectToPort:(uint32_t)port
           completion:(void (^)(void *socketHandle, int fd))completion
         errorHandler:(void (^)(NSError *error))errorHandler {
    [self.socketDevice connectToPort:port completionHandler:^(VZVirtioSocketConnection * _Nullable connection, NSError * _Nullable error) {
        if (connection) {
            void *handle = (void *)CFBridgingRetain(connection);
            completion(handle, connection.fileDescriptor);
        } else if (error) {
            errorHandler(error);
        } else {
            errorHandler([NSError errorWithDomain:@"msl" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"VSOCK connection failed"}]);
        }
    }];
}

- (void)closeSocket:(void *)socketHandle {
    if (socketHandle) {
        VZVirtioSocketConnection *connection = (__bridge VZVirtioSocketConnection *)socketHandle;
        [connection close];
        CFBridgingRelease(socketHandle);
    }
}

@end
