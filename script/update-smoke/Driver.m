#import "Driver.h"

@implementation UpdateSmokeDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply { reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]); }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { NSLog(@"SMOKE: checking"); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    if (!self.expectUpdate) { NSLog(@"SMOKE: unexpected update"); exit(2); }
    NSLog(@"SMOKE: found build %@, %@", item.versionString, item.fileURL);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { NSLog(@"SMOKE: notes %@", error); }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack {
    NSLog(@"SMOKE: up to date %@", error);
    ack(); exit(self.expectUpdate ? 3 : 0);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"SMOKE: FAILED %@", error); exit(4); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { NSLog(@"SMOKE: downloading"); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { NSLog(@"SMOKE: expected %llu bytes", length); }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { NSLog(@"SMOKE: extracting"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { NSLog(@"SMOKE: installing"); reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry { NSLog(@"SMOKE: application terminated %d", terminated); }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { NSLog(@"SMOKE: INSTALLED relaunched=%d", relaunched); ack(); exit(relaunched ? 0 : 5); }
- (void)dismissUpdateInstallation {}
@end
