#import <Virtualization/Virtualization.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper for the Virtio socket device API.
/// VZVirtioSocketDevice and VZVirtioSocketConnection are not exposed to Swift
/// in the Virtualization framework module, so we bridge them here.
@interface MSLVSOCK : NSObject

/// Add a virtio socket configuration to the VM config.
/// Must be called before the VM is created.
- (instancetype)initWithConfiguration:(VZVirtualMachineConfiguration *)config;

/// After the VM is created, call this with the VM's socket devices.
- (void)setVM:(VZVirtualMachine *)vm;

/// Connect to the guest on the given port.
/// socketHandle must be passed to closeSocket: when done.
- (void)connectToPort:(uint32_t)port
           completion:(void (^)(void *socketHandle, int fd))completion
         errorHandler:(void (^)(NSError *error))errorHandler;

/// Close a socket previously returned by connectToPort:completion:errorHandler:.
- (void)closeSocket:(void *)socketHandle;

@end

NS_ASSUME_NONNULL_END
