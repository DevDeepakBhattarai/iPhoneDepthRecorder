#import <UIKit/UIKit.h>
@class CaptureEngine;

@interface RecorderSettingsViewController : UITableViewController
- (instancetype)initWithEngine:(CaptureEngine *)engine
                    dofEnabled:(BOOL)dofEnabled
                      setDOF:(void (^)(BOOL enabled))setDOF;
@end
