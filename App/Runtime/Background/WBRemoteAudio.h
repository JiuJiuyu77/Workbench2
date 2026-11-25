#import <Foundation/Foundation.h>
BOOL WBRemoteAudioEnabled(void);
void WBRemoteAudioSetEnabled(BOOL enabled);
BOOL WBRemoteAudioStart(void);
void WBRemoteAudioStop(void);
BOOL WBRemoteAudioPlaying(void);
NSDictionary *WBRemoteAudioDiagnostics(void);
// Main-thread callback for interruptions, playback failures and resumes.
void WBRemoteAudioObserve(void (^changed)(void));

// Idempotent main-thread leases; one consumer cannot stop another consumer.
BOOL WBRemoteAudioAcquire(NSString *owner);
void WBRemoteAudioRelease(NSString *owner);
