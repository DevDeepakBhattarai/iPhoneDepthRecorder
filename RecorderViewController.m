#import "RecorderViewController.h"
#import "CaptureEngine.h"
#import "PreviewRenderer.h"
#import "RemoteControlServer.h"
#import "RecorderSettingsViewController.h"
#import <AVFoundation/AVFoundation.h>

static UIColor *DRYellow(void){return [UIColor colorWithRed:1 green:.84 blue:.04 alpha:1];}
static UIColor *DRRed(void){return [UIColor colorWithRed:1 green:.23 blue:.19 alpha:1];}
static UIColor *DRGreen(void){return [UIColor colorWithRed:.20 green:.82 blue:.36 alpha:1];}

typedef NS_ENUM(NSInteger, DRControlTarget) {DRControlExposure,DRControlFocus,DRControlWB,DRControlISO,DRControlShutter};

@interface RecorderViewController () <CaptureEngineDelegate,UIGestureRecognizerDelegate>
@property(nonatomic,strong) CaptureEngine *engine;
@property(nonatomic,strong) PreviewRenderer *previewRenderer;
@property(nonatomic,strong) RemoteControlServer *remoteServer;
@property(nonatomic,strong) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic,strong) UIView *previewContainer,*previewGestureView,*audioMeter,*focusReticle,*recordGlyph;
@property(nonatomic,strong) UILabel *focusTag,*evLabel,*afLabel,*wbLabel,*tintLabel,*deviceLabel,*batteryLabel,*timeLabel,*formatLabel,*controlReadout;
@property(nonatomic,strong) UIVisualEffectView *statusCard,*controlDock,*adjustTray;
@property(nonatomic,strong) UIButton *lens13,*lens26,*lens65,*leftButton,*adjustButton,*depthButton,*focusButton,*lightButton,*recordButton,*flipButton,*closeTrayButton,*micButton;
@property(nonatomic,strong) UISlider *controlSlider;
@property(nonatomic,strong) UIStackView *chipRow;
@property(nonatomic,strong) NSTimer *recordTimer,*uiTimer;
@property(nonatomic,strong) NSDate *recordStartDate;
@property(nonatomic) DRControlTarget controlTarget;
@property(nonatomic) BOOL prepared,visuallyRecording,trayOpen,lockingAEAFWB,lensSwitchInFlight;
@property(nonatomic) CGFloat pinchBaseZoom;
@end

@implementation RecorderViewController

- (UIVisualEffectView *)glass:(CGFloat)r {
    UIVisualEffectView *v=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    v.layer.cornerRadius=r;v.layer.masksToBounds=YES;v.layer.borderWidth=.5;v.layer.borderColor=[UIColor colorWithWhite:1 alpha:.10].CGColor;return v;
}
- (UIButton *)roundButton:(NSString *)symbol {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];b.tintColor=UIColor.whiteColor;b.backgroundColor=[UIColor colorWithWhite:.10 alpha:.82];b.layer.borderWidth=.5;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.10].CGColor;[b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];return b;
}
- (UILabel *)meter:(NSString *)text {
    UILabel *l=[[UILabel alloc] init];l.text=text;l.textAlignment=NSTextAlignmentCenter;l.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium];l.textColor=[UIColor colorWithWhite:1 alpha:.78];l.backgroundColor=[UIColor colorWithWhite:.13 alpha:.95];l.layer.cornerRadius=10;l.layer.masksToBounds=YES;return l;
}
- (UIButton *)lens:(NSString *)title index:(NSInteger)i {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];b.tag=i;b.titleLabel.font=[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];b.titleLabel.numberOfLines=2;b.titleLabel.textAlignment=NSTextAlignmentCenter;[b setTitle:title forState:UIControlStateNormal];[b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];[b addTarget:self action:@selector(lensTapped:) forControlEvents:UIControlEventTouchUpInside];return b;
}
- (UIButton *)chip:(NSString *)title target:(DRControlTarget)t {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];b.tag=t;b.backgroundColor=[UIColor colorWithWhite:1 alpha:.08];b.layer.cornerRadius=8;b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];[b setTitle:title forState:UIControlStateNormal];[b setTitleColor:[UIColor colorWithWhite:1 alpha:.78] forState:UIControlStateNormal];[b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.blackColor;UIDevice.currentDevice.batteryMonitoringEnabled=YES;self.controlTarget=DRControlExposure;
    self.engine=[[CaptureEngine alloc] init];self.engine.delegate=self;
    self.remoteServer=[[RemoteControlServer alloc] initWithEngine:self.engine port:9989];NSError *serverError=nil;[self.remoteServer start:&serverError];

    self.audioMeter=[[UIView alloc] init];self.audioMeter.backgroundColor=[UIColor colorWithWhite:.12 alpha:1];self.audioMeter.layer.cornerRadius=8;[self.view addSubview:self.audioMeter];
    for(int r=0;r<2;r++){UIView *g=[[UIView alloc] initWithFrame:CGRectMake(9,5+r*7,20,4)];g.backgroundColor=DRGreen();g.layer.cornerRadius=2;[self.audioMeter addSubview:g];UIView *d=[[UIView alloc] initWithFrame:CGRectMake(32,5+r*7,34,4)];d.backgroundColor=[UIColor colorWithWhite:.36 alpha:.6];d.layer.cornerRadius=2;[self.audioMeter addSubview:d];}
    self.evLabel=[self meter:@"± 0.0 EV"];self.afLabel=[self meter:@"⌖ AF"];self.wbLabel=[self meter:@"5000 K"];self.tintLabel=[self meter:@"◐ 0"];
    for(UILabel *l in @[self.evLabel,self.afLabel,self.wbLabel,self.tintLabel]){l.userInteractionEnabled=YES;[self.view addSubview:l];}
    [self.evLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openExposure)]];
    [self.afLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openFocus)]];
    [self.wbLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openWB)]];
    [self.tintLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openWB)]];

    self.previewContainer=[[UIView alloc] init];self.previewContainer.backgroundColor=UIColor.blackColor;self.previewContainer.layer.cornerRadius=0;self.previewContainer.layer.masksToBounds=YES;[self.view addSubview:self.previewContainer];
    self.previewLayer=[AVCaptureVideoPreviewLayer layerWithSession:self.engine.session];self.previewLayer.videoGravity=AVLayerVideoGravityResizeAspectFill;[self.previewContainer.layer addSublayer:self.previewLayer];
    self.previewRenderer=[[PreviewRenderer alloc] initWithFrame:CGRectZero];if(self.previewRenderer){self.previewRenderer.view.hidden=YES;self.previewRenderer.enabled=YES;[self.previewContainer addSubview:self.previewRenderer.view];self.engine.previewEnabled=YES;}
    self.previewGestureView=[[UIView alloc] init];self.previewGestureView.backgroundColor=UIColor.clearColor;[self.previewContainer addSubview:self.previewGestureView];
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(previewTapped:)];tap.delegate=self;[self.previewGestureView addGestureRecognizer:tap];
    UILongPressGestureRecognizer *hold=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(previewLongPressed:)];hold.minimumPressDuration=.55;hold.delegate=self;[self.previewGestureView addGestureRecognizer:hold];
    UIPinchGestureRecognizer *pinch=[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(previewPinched:)];pinch.delegate=self;[self.previewGestureView addGestureRecognizer:pinch];
    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(previewPanned:)];pan.delegate=self;pan.maximumNumberOfTouches=1;[self.previewGestureView addGestureRecognizer:pan];
    // Keep telemetry over the live image instead of reserving a separate header band.
    for(UIView *v in @[self.audioMeter,self.evLabel,self.afLabel,self.wbLabel,self.tintLabel])[self.previewContainer addSubview:v];
    self.statusCard=[self glass:15];[self.previewContainer addSubview:self.statusCard];
    self.deviceLabel=[[UILabel alloc] init];self.deviceLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium];self.deviceLabel.textColor=[UIColor colorWithWhite:1 alpha:.62];self.deviceLabel.text=@"▯ iPhone";
    self.batteryLabel=[[UILabel alloc] init];self.batteryLabel.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];self.batteryLabel.textColor=[UIColor colorWithWhite:1 alpha:.82];self.batteryLabel.textAlignment=NSTextAlignmentRight;
    self.timeLabel=[[UILabel alloc] init];self.timeLabel.font=[UIFont systemFontOfSize:19 weight:UIFontWeightBold];self.timeLabel.textColor=UIColor.whiteColor;self.timeLabel.text=@"--m";
    self.formatLabel=[[UILabel alloc] init];self.formatLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium];self.formatLabel.textColor=[UIColor colorWithWhite:1 alpha:.52];self.formatLabel.text=@"4K · 30 · HEVC · LiDAR";
    for(UIView *v in @[self.deviceLabel,self.batteryLabel,self.timeLabel,self.formatLabel])[self.statusCard.contentView addSubview:v];

    self.lens13=[self lens:@"13" index:0];self.lens26=[self lens:@"26\nMM" index:1];self.lens65=[self lens:@"65" index:2];
    for(UIButton *b in @[self.lens13,self.lens26,self.lens65])[self.previewContainer addSubview:b];

    self.leftButton=[self roundButton:@"video.badge.plus"];[self.leftButton addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];[self.previewContainer addSubview:self.leftButton];
    self.controlDock=[self glass:24];[self.previewContainer addSubview:self.controlDock];
    self.adjustButton=[self roundButton:@"switch.2"];self.adjustButton.backgroundColor=UIColor.clearColor;[self.adjustButton addTarget:self action:@selector(openExposure) forControlEvents:UIControlEventTouchUpInside];
    self.depthButton=[self roundButton:@"square.3.layers.3d"];self.depthButton.backgroundColor=UIColor.clearColor;[self.depthButton addTarget:self action:@selector(toggleDepthPreview) forControlEvents:UIControlEventTouchUpInside];
    self.focusButton=[self roundButton:@"viewfinder"];self.focusButton.backgroundColor=UIColor.clearColor;[self.focusButton addTarget:self action:@selector(openFocus) forControlEvents:UIControlEventTouchUpInside];
    for(UIButton *b in @[self.adjustButton,self.depthButton,self.focusButton])[self.controlDock.contentView addSubview:b];
    self.lightButton=[self roundButton:@"sun.max.fill"];[self.lightButton addTarget:self action:@selector(toggleTorch) forControlEvents:UIControlEventTouchUpInside];[self.previewContainer addSubview:self.lightButton];

    self.adjustTray=[self glass:14];self.adjustTray.hidden=YES;[self.previewContainer addSubview:self.adjustTray];
    self.chipRow=[[UIStackView alloc] init];self.chipRow.axis=UILayoutConstraintAxisHorizontal;self.chipRow.distribution=UIStackViewDistributionFillEqually;self.chipRow.spacing=4;[self.adjustTray.contentView addSubview:self.chipRow];
    for(UIButton *b in @[[self chip:@"EV" target:DRControlExposure],[self chip:@"AF" target:DRControlFocus],[self chip:@"WB" target:DRControlWB],[self chip:@"ISO" target:DRControlISO],[self chip:@"SHUT" target:DRControlShutter]])[self.chipRow addArrangedSubview:b];
    self.controlReadout=[[UILabel alloc] init];self.controlReadout.textAlignment=NSTextAlignmentCenter;self.controlReadout.textColor=DRYellow();self.controlReadout.font=[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];[self.adjustTray.contentView addSubview:self.controlReadout];
    self.controlSlider=[[UISlider alloc] init];self.controlSlider.minimumValue=0;self.controlSlider.maximumValue=1;self.controlSlider.minimumTrackTintColor=DRYellow();self.controlSlider.maximumTrackTintColor=[UIColor colorWithWhite:1 alpha:.2];[self.controlSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[self.adjustTray.contentView addSubview:self.controlSlider];
    self.micButton=[self roundButton:@"mic.fill"];[self.micButton addTarget:self action:@selector(toggleMic) forControlEvents:UIControlEventTouchUpInside];[self.adjustTray.contentView addSubview:self.micButton];
    self.closeTrayButton=[self roundButton:@"chevron.down"];[self.closeTrayButton addTarget:self action:@selector(closeTray) forControlEvents:UIControlEventTouchUpInside];[self.adjustTray.contentView addSubview:self.closeTrayButton];

    self.focusReticle=[[UIView alloc] init];self.focusReticle.layer.cornerRadius=4;self.focusReticle.layer.borderWidth=1.5;self.focusReticle.layer.borderColor=DRYellow().CGColor;self.focusReticle.alpha=0;self.focusReticle.userInteractionEnabled=NO;[self.previewContainer addSubview:self.focusReticle];
    self.focusTag=[[UILabel alloc] init];self.focusTag.text=@"AE/AF/WB LOCK";self.focusTag.textAlignment=NSTextAlignmentCenter;self.focusTag.font=[UIFont systemFontOfSize:9 weight:UIFontWeightBold];self.focusTag.textColor=UIColor.blackColor;self.focusTag.backgroundColor=DRYellow();self.focusTag.layer.cornerRadius=10;self.focusTag.layer.masksToBounds=YES;self.focusTag.alpha=0;self.focusTag.userInteractionEnabled=NO;[self.previewContainer addSubview:self.focusTag];

    self.recordButton=[UIButton buttonWithType:UIButtonTypeCustom];self.recordButton.backgroundColor=[UIColor colorWithWhite:.05 alpha:1];self.recordButton.layer.borderWidth=2;self.recordButton.layer.borderColor=[UIColor colorWithWhite:1 alpha:.72].CGColor;self.recordButton.enabled=NO;[self.recordButton addTarget:self action:@selector(recordTapped) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.recordButton];
    self.recordGlyph=[[UIView alloc] init];self.recordGlyph.backgroundColor=DRRed();self.recordGlyph.userInteractionEnabled=NO;[self.recordButton addSubview:self.recordGlyph];
    self.flipButton=[self roundButton:@"arrow.triangle.2.circlepath.camera"];[self.flipButton addTarget:self action:@selector(flipCamera) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.flipButton];
    [self refreshUI];
}

- (CGFloat)scaleX{return CGRectGetWidth(self.view.bounds)/428.0;}
- (CGFloat)scaleY{return CGRectGetHeight(self.view.bounds)/926.0;}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds=self.view.bounds;
    CGFloat W=CGRectGetWidth(bounds),H=CGRectGetHeight(bounds);
    if(W<=0||H<=0)return;
    UIEdgeInsets safe=self.view.safeAreaInsets;
    BOOL portrait=H>=W;
    CGFloat s=MIN(1.0,MAX(.88,MIN(W,H)/428.0));
    CGFloat side=14*s;

    // The preview owns the entire viewport. Controls overlay it and respect safe areas.
    self.previewContainer.frame=bounds;
    self.previewLayer.frame=self.previewContainer.bounds;
    AVCaptureConnection *conn=self.previewLayer.connection;
    if(conn.isVideoOrientationSupported)conn.videoOrientation=[self videoOrientation];
    self.previewGestureView.frame=self.previewContainer.bounds;
    if(self.previewRenderer){
        self.previewRenderer.view.frame=self.previewContainer.bounds;
        self.previewRenderer.interfaceOrientation=[self orientation];
        [self.previewRenderer updateDrawableSizeForBounds:self.previewRenderer.view.bounds screenScale:UIScreen.mainScreen.scale];
    }

    // Compact telemetry floats below the notch instead of consuming a header band.
    CGFloat meterH=24*s,gap=8*s;
    CGFloat audioW=76*s,evW=62*s,afW=54*s,wbW=64*s,tintW=46*s;
    CGFloat rowW=audioW+evW+afW+wbW+tintW+gap*4;
    CGFloat minRowX=safe.left+side,maxRowX=W-safe.right-side-rowW;
    CGFloat rowX=MAX(minRowX,(W-rowW)/2.0);
    if(maxRowX>=minRowX)rowX=MIN(rowX,maxRowX);
    CGFloat meterY=safe.top+8*s;
    self.audioMeter.frame=CGRectMake(rowX,meterY,audioW,meterH);
    CGFloat x=CGRectGetMaxX(self.audioMeter.frame)+gap;
    self.evLabel.frame=CGRectMake(x,meterY+1*s,evW,meterH-2*s);x=CGRectGetMaxX(self.evLabel.frame)+gap;
    self.afLabel.frame=CGRectMake(x,meterY+1*s,afW,meterH-2*s);x=CGRectGetMaxX(self.afLabel.frame)+gap;
    self.wbLabel.frame=CGRectMake(x,meterY+1*s,wbW,meterH-2*s);x=CGRectGetMaxX(self.wbLabel.frame)+gap;
    self.tintLabel.frame=CGRectMake(x,meterY+1*s,tintW,meterH-2*s);

    CGFloat statusW=176*s,statusH=80*s;
    CGFloat statusX=safe.left+side,statusY=CGRectGetMaxY(self.audioMeter.frame)+10*s;
    self.statusCard.frame=CGRectMake(statusX,statusY,statusW,statusH);
    self.deviceLabel.frame=CGRectMake(13*s,9*s,101*s,16*s);
    self.batteryLabel.frame=CGRectMake(statusW-65*s,9*s,52*s,16*s);
    self.timeLabel.frame=CGRectMake(13*s,30*s,statusW-26*s,24*s);
    self.formatLabel.frame=CGRectMake(13*s,56*s,statusW-26*s,15*s);

    // Keep the recording controls low and compact, anchored above the home indicator.
    CGFloat rec=62*s;
    CGFloat bottom=H-safe.bottom-10*s;
    CGFloat recY=bottom-rec;
    self.recordButton.frame=CGRectMake((W-rec)/2.0,recY,rec,rec);
    self.recordButton.layer.cornerRadius=rec/2.0;
    CGFloat glyph=self.visuallyRecording?24*s:50*s;
    self.recordGlyph.frame=CGRectMake((rec-glyph)/2.0,(rec-glyph)/2.0,glyph,glyph);
    self.recordGlyph.layer.cornerRadius=self.visuallyRecording?5*s:glyph/2.0;

    CGFloat utility=44*s,utilityY=recY-62*s;
    self.leftButton.frame=CGRectMake(safe.left+side,utilityY,utility,utility);
    self.leftButton.layer.cornerRadius=utility/2.0;
    self.lightButton.frame=CGRectMake(W-safe.right-side-utility,utilityY,utility,utility);
    self.lightButton.layer.cornerRadius=utility/2.0;

    CGFloat dockW=166*s,dockH=46*s;
    self.controlDock.frame=CGRectMake((W-dockW)/2.0,utilityY-1*s,dockW,dockH);
    CGFloat dockButton=34*s,dockY=(dockH-dockButton)/2.0;
    CGFloat dockGap=(dockW-3*dockButton)/4.0;
    self.adjustButton.frame=CGRectMake(dockGap,dockY,dockButton,dockButton);
    self.depthButton.frame=CGRectMake(dockGap*2+dockButton,dockY,dockButton,dockButton);
    self.focusButton.frame=CGRectMake(dockGap*3+dockButton*2,dockY,dockButton,dockButton);
    for(UIButton *b in @[self.adjustButton,self.depthButton,self.focusButton])b.layer.cornerRadius=dockButton/2.0;

    CGFloat lensW=44*s,lensH=38*s,lensGap=4*s;
    CGFloat lensRowW=lensW*3+lensGap*2,lensY=utilityY-50*s,lensX=(W-lensRowW)/2.0;
    self.lens13.frame=CGRectMake(lensX,lensY,lensW,lensH);
    self.lens26.frame=CGRectMake(lensX+lensW+lensGap,lensY,lensW,lensH);
    self.lens65.frame=CGRectMake(lensX+(lensW+lensGap)*2,lensY,lensW,lensH);

    CGFloat flip=44*s;
    self.flipButton.frame=CGRectMake(W-safe.right-side-flip,recY+(rec-flip)/2.0,flip,flip);
    self.flipButton.layer.cornerRadius=flip/2.0;

    CGFloat trayH=136*s;
    CGFloat trayW=portrait?MAX(240*s,W-safe.left-safe.right-36*s):MIN(392*s,W-safe.left-safe.right-36*s);
    CGFloat trayX=portrait?(W-trayW)/2.0:W-safe.right-side-trayW;
    CGFloat trayY=portrait?MAX(statusY+statusH+12*s,lensY-trayH-10*s):CGRectGetMaxY(self.audioMeter.frame)+12*s;
    self.adjustTray.frame=CGRectMake(trayX,trayY,trayW,trayH);
    CGFloat tw=CGRectGetWidth(self.adjustTray.bounds);
    self.chipRow.frame=CGRectMake(10*s,10*s,tw-20*s,30*s);
    self.controlReadout.frame=CGRectMake(10*s,46*s,tw-20*s,22*s);
    self.controlSlider.frame=CGRectMake(14*s,72*s,tw-28*s,30*s);
    self.micButton.frame=CGRectMake(18*s,102*s,32*s,32*s);self.micButton.layer.cornerRadius=16*s;
    self.closeTrayButton.frame=CGRectMake(tw-50*s,102*s,32*s,32*s);self.closeTrayButton.layer.cornerRadius=16*s;

    self.focusReticle.frame=CGRectMake(0,0,70*s,70*s);
    self.focusTag.frame=CGRectMake(0,0,112*s,20*s);
    [self.engine setCaptureOrientationName:[self orientationName]];
}

- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];UIApplication.sharedApplication.idleTimerDisabled=YES;if(!self.prepared){self.prepared=YES;[self.engine prepareAndStart];}if(!self.uiTimer)self.uiTimer=[NSTimer scheduledTimerWithTimeInterval:.6 target:self selector:@selector(refreshUI) userInfo:nil repeats:YES];}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];UIApplication.sharedApplication.idleTimerDisabled=NO;[self.uiTimer invalidate];self.uiTimer=nil;}
- (BOOL)prefersStatusBarHidden{return YES;}
- (BOOL)prefersHomeIndicatorAutoHidden{return YES;}
- (UIInterfaceOrientation)orientation{UIWindowScene *s=self.view.window.windowScene;return s?s.interfaceOrientation:UIInterfaceOrientationPortrait;}
- (AVCaptureVideoOrientation)videoOrientation{switch([self orientation]){case UIInterfaceOrientationLandscapeLeft:return AVCaptureVideoOrientationLandscapeLeft;case UIInterfaceOrientationLandscapeRight:return AVCaptureVideoOrientationLandscapeRight;case UIInterfaceOrientationPortraitUpsideDown:return AVCaptureVideoOrientationPortraitUpsideDown;default:return AVCaptureVideoOrientationPortrait;}}
- (NSString *)orientationName{switch([self orientation]){case UIInterfaceOrientationLandscapeLeft:return @"landscapeLeft";case UIInterfaceOrientationLandscapeRight:return @"landscapeRight";case UIInterfaceOrientationPortraitUpsideDown:return @"portraitUpsideDown";default:return @"portrait";}}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o{(void)g;(void)o;return YES;}
- (NSString *)remainingRecordTimeText {
    NSDictionary *fs=[[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];unsigned long long free=[fs[NSFileSystemFreeSize] unsignedLongLongValue];NSInteger m=(NSInteger)floor((double)free/(850.0*1024.0*1024.0));if(m<1)return @"<1m";if(m>999)return @"999m+";return [NSString stringWithFormat:@"%ldm",(long)m];
}

- (void)refreshUI {
    NSDictionary *s=[self.engine cameraControlSnapshot];if(!self.engine.isRecording&&!self.visuallyRecording&&!self.engine.isFinalizing)self.timeLabel.text=[self remainingRecordTimeText];
    self.evLabel.text=[NSString stringWithFormat:@"± %.1f EV",[s[@"control_exposure_bias"] doubleValue]];self.afLabel.text=[s[@"control_focus_manual"] boolValue]?@"⌖ MF":@"⌖ AF";self.wbLabel.text=[NSString stringWithFormat:@"%.0f K",[s[@"control_white_balance_temperature"] doubleValue]];self.tintLabel.text=[NSString stringWithFormat:@"◐ %.0f",[s[@"control_white_balance_tint"] doubleValue]];
    float batt=UIDevice.currentDevice.batteryLevel;BOOL charging=UIDevice.currentDevice.batteryState==UIDeviceBatteryStateCharging||UIDevice.currentDevice.batteryState==UIDeviceBatteryStateFull;self.batteryLabel.text=batt>=0?[NSString stringWithFormat:@"%@%.0f%%",charging?@"⚡":@"",batt*100]:@"";
    [self refreshLensRow:s];
    BOOL depthAvailable=[s[@"dof_available"] boolValue];
    self.depthButton.enabled=depthAvailable;
    self.depthButton.alpha=depthAvailable?1.0:0.28;
    self.depthButton.tintColor=(depthAvailable && self.engine.isPreviewEnabled)?DRYellow():UIColor.whiteColor;
    if(self.previewRenderer){
        self.previewRenderer.enabled=depthAvailable && self.engine.isPreviewEnabled;
        if(!depthAvailable || !self.engine.isPreviewEnabled) self.previewRenderer.view.hidden=YES;
    }
    self.micButton.tintColor=self.engine.recordAudioEnabled?DRYellow():[UIColor colorWithWhite:1 alpha:.45];
}

- (void)refreshLensRow:(NSDictionary *)s {
    BOOL front=[s[@"camera_position"] integerValue]==AVCaptureDevicePositionFront;
    NSInteger selected=[s[@"selected_rear_lens_index"] integerValue];
    NSArray *buttons=@[self.lens13,self.lens26,self.lens65];
    for(NSUInteger i=0;i<buttons.count;i++){
        UIButton *b=buttons[i];
        BOOL usable=!front && !self.lensSwitchInFlight;
        b.enabled=usable;
        b.alpha=usable?1.0:0.28;
        BOOL isSelected=usable && selected==(NSInteger)i;
        b.backgroundColor=isSelected?[UIColor colorWithWhite:.10 alpha:.74]:UIColor.clearColor;
        b.layer.cornerRadius=CGRectGetHeight(b.bounds)/2.0;
        [b setTitleColor:isSelected?DRYellow():UIColor.whiteColor forState:UIControlStateNormal];
    }
}

- (void)showFocusAt:(CGPoint)p locked:(BOOL)locked {
    self.focusReticle.center=p;self.focusReticle.alpha=.3;self.focusReticle.transform=CGAffineTransformMakeScale(1.2,1.2);self.focusTag.center=CGPointMake(p.x,p.y+50);self.focusTag.alpha=locked?1:0;
    [UIView animateWithDuration:.15 animations:^{self.focusReticle.alpha=1;self.focusReticle.transform=CGAffineTransformIdentity;} completion:^(__unused BOOL done){if(!locked)[UIView animateWithDuration:.28 delay:.7 options:0 animations:^{self.focusReticle.alpha=0;} completion:nil];}];
}
- (void)previewTapped:(UITapGestureRecognizer *)g {
    if(g.state!=UIGestureRecognizerStateEnded||self.engine.isRecording||self.trayOpen||self.lockingAEAFWB)return;CGPoint p=[g locationInView:self.previewContainer];CGPoint d=[self.previewLayer captureDevicePointOfInterestForPoint:p];[self.engine setComputationalFocusPoint:d];self.focusTag.alpha=0;[self showFocusAt:p locked:NO];
}
- (void)previewLongPressed:(UILongPressGestureRecognizer *)g {
    if(g.state!=UIGestureRecognizerStateBegan||self.engine.isRecording||self.trayOpen||self.lockingAEAFWB)return;CGPoint p=[g locationInView:self.previewContainer];CGPoint d=[self.previewLayer captureDevicePointOfInterestForPoint:p];self.lockingAEAFWB=YES;self.focusTag.text=@"LOCKING...";[self showFocusAt:p locked:YES];__weak typeof(self) w=self;
    [self.engine lockAEAFWBAtPoint:d completion:^(BOOL locked){__strong typeof(w) self=w;if(!self)return;self.lockingAEAFWB=NO;if(locked){self.focusTag.text=@"AE/AF/WB LOCK";UIImpactFeedbackGenerator *h=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];[h impactOccurred];}else{self.focusTag.text=@"LOCK FAILED";[UIView animateWithDuration:.25 delay:.7 options:0 animations:^{self.focusTag.alpha=0;self.focusReticle.alpha=0;} completion:nil];}[self refreshUI];}];
}
- (void)previewPinched:(UIPinchGestureRecognizer *)g {
    NSDictionary *s=[self.engine cameraControlSnapshot];CGFloat lo=MAX(.1,[s[@"control_zoom_min"] doubleValue]),hi=MAX(lo,[s[@"control_zoom_max"] doubleValue]);if(g.state==UIGestureRecognizerStateBegan)self.pinchBaseZoom=MIN(hi,MAX(lo,[s[@"control_zoom"] doubleValue]));if(g.state==UIGestureRecognizerStateChanged)[self.engine setZoomFactor:MIN(hi,MAX(lo,self.pinchBaseZoom*g.scale))];
}
- (void)previewPanned:(UIPanGestureRecognizer *)g {
    if(self.trayOpen||self.engine.isRecording||self.engine.isAEAFWBLocked)return;static float base=0;NSDictionary *s=[self.engine cameraControlSnapshot];if([s[@"control_exposure_manual"] boolValue])return;if(g.state==UIGestureRecognizerStateBegan)base=[s[@"control_exposure_bias"] floatValue];if(g.state==UIGestureRecognizerStateChanged){CGFloat dy=[g translationInView:self.previewContainer].y/MAX(CGRectGetHeight(self.previewContainer.bounds),1);float lo=[s[@"control_exposure_bias_min"] floatValue],hi=[s[@"control_exposure_bias_max"] floatValue];[self.engine setExposureBias:MIN(hi,MAX(lo,base-(float)dy*6))];}
}

- (void)lensTapped:(UIButton *)b {
    NSInteger i=b.tag;
    if(self.engine.isRecording||self.engine.isFinalizing||self.lockingAEAFWB||i<0||i>2)return;
    self.lensSwitchInFlight=YES;
    self.lens13.enabled=self.lens26.enabled=self.lens65.enabled=NO;
    self.timeLabel.text=[NSString stringWithFormat:@"%@ mm", i==0?@"13":(i==2?@"65":@"26")];
    if(i!=1 && self.previewRenderer){self.previewRenderer.enabled=NO;self.previewRenderer.view.hidden=YES;}
    [self.engine selectRearLensIndex:i];
}
- (void)flipCamera {
    if(self.engine.isRecording||self.engine.isFinalizing||self.lockingAEAFWB||!self.flipButton.enabled)return;
    self.flipButton.enabled=NO;[self closeTray];self.focusTag.alpha=0;self.focusReticle.alpha=0;[self.engine switchCameraPosition];
    // The engine's Ready/error callback re-enables this button. A fixed timer here
    // allowed a second switch while AVFoundation was still rebuilding its graph.
}
- (void)toggleTorch {NSDictionary *s=[self.engine cameraControlSnapshot];BOOL on=[s[@"control_torch_level"] floatValue]>0;[self.engine setTorchLevel:on?0:1];self.lightButton.tintColor=on?UIColor.whiteColor:DRYellow();}
- (void)toggleDepthPreview {if(!self.previewRenderer)return;NSDictionary *s=[self.engine cameraControlSnapshot];if(![s[@"dof_available"] boolValue]){self.previewRenderer.enabled=NO;self.previewRenderer.view.hidden=YES;return;}BOOL on=!self.engine.isPreviewEnabled;self.engine.previewEnabled=on;self.previewRenderer.enabled=on;if(!on)self.previewRenderer.view.hidden=YES;[self refreshUI];}
- (void)showSettings {
    if(self.engine.isRecording||self.engine.isFinalizing||self.presentedViewController)return;
    __weak typeof(self) w=self;RecorderSettingsViewController *vc=[[RecorderSettingsViewController alloc] initWithEngine:self.engine dofEnabled:self.engine.isPreviewEnabled setDOF:^(BOOL on){__strong typeof(w) self=w;if(!self)return;self.engine.previewEnabled=on;NSDictionary *snap=[self.engine cameraControlSnapshot];BOOL available=[snap[@"dof_available"] boolValue];if(self.previewRenderer){self.previewRenderer.enabled=on&&available;if(!on||!available)self.previewRenderer.view.hidden=YES;}[self refreshUI];}];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:vc];nav.modalPresentationStyle=UIModalPresentationPageSheet;[self presentViewController:nav animated:YES completion:nil];
}
- (void)openExposure{self.controlTarget=DRControlExposure;[self openTray];}
- (void)openFocus{self.controlTarget=DRControlFocus;[self openTray];}
- (void)openWB{self.controlTarget=DRControlWB;[self openTray];}
- (void)openTray{if(self.engine.isRecording)return;self.trayOpen=YES;self.adjustTray.hidden=NO;self.previewGestureView.userInteractionEnabled=NO;[self configureControl];}
- (void)closeTray{self.trayOpen=NO;self.adjustTray.hidden=YES;self.previewGestureView.userInteractionEnabled=YES;}
- (void)chipTapped:(UIButton *)b{self.controlTarget=(DRControlTarget)b.tag;[self configureControl];}
- (double)logSlider:(double)v min:(double)lo max:(double)hi{lo=MAX(lo,1e-8);hi=MAX(hi,lo*1.001);v=MIN(hi,MAX(lo,v));return(log(v)-log(lo))/(log(hi)-log(lo));}
- (double)logValue:(double)t min:(double)lo max:(double)hi{lo=MAX(lo,1e-8);hi=MAX(hi,lo*1.001);return exp(log(lo)+MIN(1,MAX(0,t))*(log(hi)-log(lo)));}
- (NSString *)shutterText:(double)s{return s>=1?[NSString stringWithFormat:@"%.1fs",s]:[NSString stringWithFormat:@"1/%ld",(long)llround(1.0/MAX(s,1e-6))];}

- (void)configureControl {
    NSDictionary *s=[self.engine cameraControlSnapshot];double t=.5;
    switch(self.controlTarget){
        case DRControlExposure:{double lo=[s[@"control_exposure_bias_min"] doubleValue],hi=[s[@"control_exposure_bias_max"] doubleValue],v=[s[@"control_exposure_bias"] doubleValue];t=(v-lo)/MAX(hi-lo,.001);self.controlReadout.text=[NSString stringWithFormat:@"%+.1f EV",v];break;}
        case DRControlFocus:{double v=[s[@"control_focus_position"] doubleValue];t=v;self.controlReadout.text=[s[@"control_focus_manual"] boolValue]?[NSString stringWithFormat:@"FOCUS %.2f",v]:@"FOCUS AUTO";break;}
        case DRControlWB:{double v=[s[@"control_white_balance_temperature"] doubleValue];t=(v-2500)/5500;self.controlReadout.text=[NSString stringWithFormat:@"WB %.0f K",v];break;}
        case DRControlISO:{double lo=[s[@"control_iso_min"] doubleValue],hi=[s[@"control_iso_max"] doubleValue],v=[s[@"control_iso"] doubleValue];t=[self logSlider:v min:lo max:hi];self.controlReadout.text=[NSString stringWithFormat:@"ISO %.0f",v];break;}
        case DRControlShutter:{double lo=[s[@"control_shutter_min_seconds"] doubleValue],hi=[s[@"control_shutter_max_seconds"] doubleValue],v=[s[@"control_shutter_seconds"] doubleValue];t=[self logSlider:v min:lo max:hi];self.controlReadout.text=[NSString stringWithFormat:@"SHUT %@",[self shutterText:v]];break;}
    }
    self.controlSlider.value=MIN(1,MAX(0,t));
}

- (void)sliderChanged:(UISlider *)slider {
    NSDictionary *s=[self.engine cameraControlSnapshot];double t=slider.value;self.focusTag.alpha=0;self.focusReticle.alpha=0;
    switch(self.controlTarget){
        case DRControlExposure:{double lo=[s[@"control_exposure_bias_min"] doubleValue],hi=[s[@"control_exposure_bias_max"] doubleValue];float v=(float)(lo+t*(hi-lo));[self.engine setExposureBias:v];self.controlReadout.text=[NSString stringWithFormat:@"%+.1f EV",v];break;}
        case DRControlFocus:{float v=(float)t;[self.engine setFocusLensPosition:v];self.controlReadout.text=[NSString stringWithFormat:@"FOCUS %.2f",v];break;}
        case DRControlWB:{float temp=(float)(2500+t*5500),tint=[s[@"control_white_balance_tint"] floatValue];[self.engine setWhiteBalanceTemperature:temp tint:tint];self.controlReadout.text=[NSString stringWithFormat:@"WB %.0f K",temp];break;}
        case DRControlISO:{double lo=[s[@"control_iso_min"] doubleValue],hi=[s[@"control_iso_max"] doubleValue];float iso=(float)[self logValue:t min:lo max:hi];[self.engine setManualExposureISO:iso shutterSeconds:[s[@"control_shutter_seconds"] doubleValue]];self.controlReadout.text=[NSString stringWithFormat:@"ISO %.0f",iso];break;}
        case DRControlShutter:{double lo=[s[@"control_shutter_min_seconds"] doubleValue],hi=[s[@"control_shutter_max_seconds"] doubleValue],sh=[self logValue:t min:lo max:hi];[self.engine setManualExposureISO:[s[@"control_iso"] floatValue] shutterSeconds:sh];self.controlReadout.text=[NSString stringWithFormat:@"SHUT %@",[self shutterText:sh]];break;}
    }
}
- (void)toggleMic{self.engine.recordAudioEnabled=!self.engine.recordAudioEnabled;[self refreshUI];}

- (void)setRecordingAppearance:(BOOL)on {
    self.visuallyRecording=on;self.flipButton.hidden=on;self.leftButton.hidden=on;self.controlDock.hidden=on;self.lightButton.hidden=on;self.lens13.hidden=on;self.lens26.hidden=on;self.lens65.hidden=on;self.adjustTray.hidden=YES;self.trayOpen=NO;self.previewGestureView.userInteractionEnabled=!on;self.previewContainer.layer.borderWidth=on?3:0;self.previewContainer.layer.borderColor=DRRed().CGColor;[self.view setNeedsLayout];
    if(on){self.recordStartDate=[NSDate date];[self.recordTimer invalidate];self.recordTimer=[NSTimer scheduledTimerWithTimeInterval:.25 target:self selector:@selector(updateRecordClock) userInfo:nil repeats:YES];[self updateRecordClock];}
    else{[self.recordTimer invalidate];self.recordTimer=nil;self.recordStartDate=nil;self.flipButton.hidden=NO;self.leftButton.hidden=NO;self.controlDock.hidden=NO;self.lightButton.hidden=NO;self.lens13.hidden=NO;self.lens26.hidden=NO;self.lens65.hidden=NO;self.previewGestureView.userInteractionEnabled=YES;}
}
- (void)updateRecordClock{if(!self.recordStartDate)return;NSUInteger t=(NSUInteger)MAX(0,floor(-[self.recordStartDate timeIntervalSinceNow]));self.timeLabel.text=[NSString stringWithFormat:@"%02lu:%02lu",(unsigned long)(t/60),(unsigned long)(t%60)];self.timeLabel.textColor=DRRed();}
- (void)recordTapped{
    if(self.engine.isFinalizing)return;
    if(self.engine.isRecording||self.visuallyRecording){self.recordButton.enabled=NO;self.timeLabel.text=@"Saving";[self.engine stopRecording];return;}
    if(!self.engine.session.isRunning)return;
    self.recordButton.enabled=NO;self.flipButton.enabled=NO;self.timeLabel.text=@"Starting";[self.engine setCaptureOrientationName:[self orientationName]];[self.engine startRecording];
}

- (void)captureEngine:(CaptureEngine *)engine didUpdateStatus:(NSString *)status {
    if([status hasPrefix:@"Ready"]){self.lensSwitchInFlight=NO;self.recordButton.enabled=YES;self.flipButton.enabled=YES;self.timeLabel.textColor=UIColor.whiteColor;self.timeLabel.text=[self remainingRecordTimeText];NSDictionary *s=[engine cameraControlSnapshot];self.deviceLabel.text=[s[@"camera_position"] integerValue]==AVCaptureDevicePositionFront?@"▯ iPhone · Front":@"▯ iPhone · Rear";NSString *fmt=engine.selectedFormatSummary?:@"4K · 30 · LiDAR";self.formatLabel.text=[fmt stringByReplacingOccurrencesOfString:@" | " withString:@" · "];[self setRecordingAppearance:NO];[self refreshUI];return;}
    if([status hasPrefix:@"Recording ->"]){self.recordButton.enabled=YES;self.flipButton.enabled=NO;[self setRecordingAppearance:YES];return;}
    if([status hasPrefix:@"Finalizing"]){self.timeLabel.text=@"Saving";self.recordButton.enabled=NO;self.flipButton.enabled=NO;return;}
    if([status hasPrefix:@"Recorder start failed"]||[status hasPrefix:@"Recorder is not ready"]){[self setRecordingAppearance:NO];self.timeLabel.text=@"Ready";self.timeLabel.textColor=UIColor.whiteColor;self.recordButton.enabled=engine.session.isRunning;self.flipButton.enabled=engine.session.isRunning;return;}
    if([status containsString:@"failed"]||[status containsString:@"Cannot"]||[status containsString:@"Could not"]||[status containsString:@"not available"]||[status containsString:@"No rear"]){self.lensSwitchInFlight=NO;[self setRecordingAppearance:NO];self.timeLabel.text=@"Camera error";self.timeLabel.textColor=DRRed();self.recordButton.enabled=NO;self.flipButton.enabled=YES;}
}
- (void)captureEngine:(CaptureEngine *)engine didUpdateTelemetry:(NSString *)telemetry{(void)engine;(void)telemetry;}
- (void)captureEngine:(CaptureEngine *)engine didOutputPreviewPixelBuffer:(CVPixelBufferRef)pixelBuffer depthData:(AVDepthData *)depthData{if(self.previewRenderer&&engine.isPreviewEnabled)[self.previewRenderer submitPixelBuffer:pixelBuffer depthData:depthData focusPoint:engine.computationalFocusPoint];}
- (void)captureEngine:(CaptureEngine *)engine recordingDidFinishAtURL:(NSURL *)url error:(NSError *)error{[self setRecordingAppearance:NO];self.recordButton.enabled=engine.session.isRunning;self.flipButton.enabled=engine.session.isRunning;self.timeLabel.textColor=UIColor.whiteColor;if(error)self.timeLabel.text=@"Save failed";else{self.timeLabel.text=@"Saved";dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(!self.engine.isRecording&&!self.engine.isFinalizing)self.timeLabel.text=[self remainingRecordTimeText];});}(void)url;}

@end
