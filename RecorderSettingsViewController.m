#import "RecorderSettingsViewController.h"
#import "CaptureEngine.h"

@interface RecorderSettingsViewController ()
@property(nonatomic,weak) CaptureEngine *engine;
@property(nonatomic,copy) void (^setDOF)(BOOL enabled);
@property(nonatomic) BOOL dofEnabled;
@end

@implementation RecorderSettingsViewController

- (instancetype)initWithEngine:(CaptureEngine *)engine dofEnabled:(BOOL)dofEnabled setDOF:(void (^)(BOOL))setDOF {
    self=[super initWithStyle:UITableViewStyleInsetGrouped];
    if(self){_engine=engine;_dofEnabled=dofEnabled;_setDOF=[setDOF copy];self.title=@"Settings";}
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch(section){case 0:return 3;case 1:return 2;case 2:return 3;default:return 2;}
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch(section){case 0:return @"Camera";case 1:return @"Recording";case 2:return @"Workflow";default:return @"Advanced";}
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if(section==0)return @"4K UHD 16:9 is the default because it is the standard video/OBS frame. Full sensor keeps 4032x3024 4:3 and takes effect after relaunch.";
    if(section==2)return @"OBS sends tiny USB start/stop commands only. The full RGB-D master stays on the phone until recording ends.";
    return nil;
}

- (UITableViewCell *)cellWithTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=title;
    UIImage *img=[UIImage systemImageNamed:symbol];
    if(img){cell.imageView.image=[img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];cell.imageView.tintColor=color;}
    cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *snap=[self.engine cameraControlSnapshot];
    if(indexPath.section==0){
        if(indexPath.row==0){
            UITableViewCell *c=[self cellWithTitle:@"Capture format" symbol:@"rectangle.stack" color:UIColor.systemBlueColor];
            c.detailTextLabel.text=self.engine.selectedFormatSummary.length?self.engine.selectedFormatSummary:@"4K UHD 16:9 + LiDAR";
            c.selectionStyle=UITableViewCellSelectionStyleNone; return c;
        }
        if(indexPath.row==1){
            UITableViewCell *c=[self cellWithTitle:@"Full sensor 4:3" symbol:@"crop" color:UIColor.systemOrangeColor];
            UISwitch *sw=[[UISwitch alloc] init];sw.on=[[NSUserDefaults standardUserDefaults] boolForKey:@"DRPreferFullSensor"];sw.tag=101;[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.detailTextLabel.text=@"Restart required";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;
        }
        UITableViewCell *c=[self cellWithTitle:@"AE/AF/WB lock" symbol:@"lock.rectangle.stack.fill" color:[UIColor colorWithRed:1 green:.84 blue:.04 alpha:1]];
        c.detailTextLabel.text=[snap[@"control_ae_af_wb_locked"] boolValue]?@"Locked":@"Press and hold on preview";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;
    }
    if(indexPath.section==1){
        if(indexPath.row==0){UITableViewCell *c=[self cellWithTitle:@"Phone microphone" symbol:@"mic.fill" color:UIColor.systemGreenColor];UISwitch *sw=[[UISwitch alloc] init];sw.on=self.engine.recordAudioEnabled;sw.tag=201;[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}
        UITableViewCell *c=[self cellWithTitle:@"Live DOF preview" symbol:@"person.fill.viewfinder" color:UIColor.systemGreenColor];UISwitch *sw=[[UISwitch alloc] init];sw.on=self.dofEnabled;sw.tag=202;[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.detailTextLabel.text=@"Preview only; master remains clean";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;
    }
    if(indexPath.section==2){
        if(indexPath.row==0){UITableViewCell *c=[self cellWithTitle:@"OBS USB control" symbol:@"cable.connector" color:UIColor.systemGreenColor];c.detailTextLabel.text=@"Enabled · local master recording";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}
        if(indexPath.row==1){UITableViewCell *c=[self cellWithTitle:@"UTC timecode" symbol:@"clock.badge.checkmark" color:UIColor.systemBlueColor];c.detailTextLabel.text=@"Per-frame Unix nanoseconds + tmcd";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}
        UITableViewCell *c=[self cellWithTitle:@"Post pipeline" symbol:@"wand.and.stars" color:UIColor.systemPurpleColor];c.detailTextLabel.text=@"LiDAR + person matte + bidirectional DOF";c.selectionStyle=UITableViewCellSelectionStyleNone;return c;
    }
    if(indexPath.row==0){UITableViewCell *c=[self cellWithTitle:@"Camera diagnostics" symbol:@"list.bullet.rectangle" color:UIColor.systemGrayColor];c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c;}
    UITableViewCell *c=[self cellWithTitle:@"Depth Recorder" symbol:@"camera.fill" color:UIColor.systemGrayColor];c.detailTextLabel.text=[NSString stringWithFormat:@"Version %@ (%@)",NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]?:@"",NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]?:@""];c.selectionStyle=UITableViewCellSelectionStyleNone;return c;
}

- (void)toggle:(UISwitch *)sender {
    if(sender.tag==101){[[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"DRPreferFullSensor"];return;}
    if(sender.tag==201){self.engine.recordAudioEnabled=sender.on;return;}
    if(sender.tag==202){self.dofEnabled=sender.on;if(self.setDOF)self.setDOF(sender.on);return;}
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(indexPath.section!=3||indexPath.row!=0)return;
    UIViewController *vc=[[UIViewController alloc] init];vc.title=@"Camera diagnostics";vc.view.backgroundColor=UIColor.systemBackgroundColor;
    UITextView *tv=[[UITextView alloc] initWithFrame:vc.view.bounds];tv.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;tv.editable=NO;tv.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];tv.text=self.engine.capabilitiesText?:@"No diagnostics available.";tv.textContainerInset=UIEdgeInsetsMake(16,14,24,14);[vc.view addSubview:tv];
    [self.navigationController pushViewController:vc animated:YES];
}
@end
