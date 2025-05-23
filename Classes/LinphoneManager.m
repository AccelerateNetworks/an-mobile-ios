/*
 * Copyright (c) 2010-2020 Belledonne Communications SARL.
 *
 * This file is part of linphone-iphone
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <sys/sysctl.h>

#import "linphoneapp-Swift.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "LinphoneCoreSettingsStore.h"
#import "LinphoneAppDelegate.h"
#import "LinphoneManager.h"
#import "Utils/FileTransferDelegate.h"

#include "linphone/factory.h"
#include "linphone/linphonecore_utils.h"
#include "linphone/lpconfig.h"
#include "mediastreamer2/mscommon.h"

#import "LinphoneIOSVersion.h"

#import "Utils.h"
#import "PhoneMainView.h"
#import "ChatsListView.h"
#import "ChatConversationView.h"
#import <UserNotifications/UserNotifications.h>

#define LINPHONE_LOGS_MAX_ENTRY 5000

static LinphoneCore *theLinphoneCore = nil;
static LinphoneManager *theLinphoneManager = nil;

NSString *const LINPHONERC_APPLICATION_KEY = @"app";

NSString *const kLinphoneCoreUpdate = @"LinphoneCoreUpdate";
NSString *const kLinphoneDisplayStatusUpdate = @"LinphoneDisplayStatusUpdate";
NSString *const kLinphoneMessageReceived = @"LinphoneMessageReceived";
NSString *const kLinphoneTextComposeEvent = @"LinphoneTextComposeStarted";
NSString *const kLinphoneCallUpdate = @"LinphoneCallUpdate";
NSString *const kLinphoneRegistrationUpdate = @"LinphoneRegistrationUpdate";
NSString *const kLinphoneAddressBookUpdate = @"LinphoneAddressBookUpdate";
NSString *const kLinphoneMainViewChange = @"LinphoneMainViewChange";
NSString *const kLinphoneLogsUpdate = @"LinphoneLogsUpdate";
NSString *const kLinphoneSettingsUpdate = @"LinphoneSettingsUpdate";
NSString *const kLinphoneBluetoothAvailabilityUpdate = @"LinphoneBluetoothAvailabilityUpdate";
NSString *const kLinphoneConfiguringStateUpdate = @"LinphoneConfiguringStateUpdate";
NSString *const kLinphoneGlobalStateUpdate = @"LinphoneGlobalStateUpdate";
NSString *const kLinphoneNotifyReceived = @"LinphoneNotifyReceived";
NSString *const kLinphoneNotifyPresenceReceivedForUriOrTel = @"LinphoneNotifyPresenceReceivedForUriOrTel";
NSString *const kLinphoneCallEncryptionChanged = @"LinphoneCallEncryptionChanged";
NSString *const kLinphoneFileTransferSendUpdate = @"LinphoneFileTransferSendUpdate";
NSString *const kLinphoneFileTransferRecvUpdate = @"LinphoneFileTransferRecvUpdate";
NSString *const kLinphoneQRCodeFound = @"LinphoneQRCodeFound";
NSString *const kLinphoneChatCreateViewChange = @"LinphoneChatCreateViewChange";
NSString *const kLinphoneEphemeralMessageDeletedInRoom = @"LinphoneEphemeralMessageDeletedInRoom";
NSString *const kLinphoneVoiceMessagePlayerEOF = @"LinphoneVoiceMessagePlayerEOF";
NSString *const kLinphoneVoiceMessagePlayerLostFocus = @"LinphoneVoiceMessagePlayerLostFocus";
NSString *const kLinphoneConfStateChanged = @"kLinphoneConfStateChanged";
NSString *const kLinphoneConfStateParticipantListChanged = @"kLinphoneConfStateParticipantListChanged";
NSString *const kLinphoneMagicSearchStarted = @"LinphoneMagicSearchStarted";
NSString *const kLinphoneMagicSearchFinished = @"LinphoneMagicSearchFinished";
NSString *const kLinphoneMagicSearchMoreAvailable = @"LinphoneMagicSearchMoreAvailable";
NSString *const kDisplayModeChanged = @"DisplayModeChanged";
NSString *const kLinphoneAccountCreationAuthenticationTokenReceived = @"LinphoneAccountCreationAuthenticationTokenReceived";

NSString *const kLinphoneMsgNotificationAppGroupId = @"group.com.acceleratenetworks.mobile";

const int kLinphoneAudioVbrCodecDefaultBitrate = 36; /*you can override this from linphonerc or linphonerc-factory*/

extern void libmsamr_init(MSFactory *factory);
extern void libmsopenh264_init(MSFactory *factory);
extern void libmssilk_init(MSFactory *factory);
extern void libmswebrtc_init(MSFactory *factory);
extern void libmscodec2_init(MSFactory *factory);

#define FRONT_CAM_NAME							\
	"AV Capture: com.apple.avfoundation.avcapturedevice.built-in_video:1" /*"AV Capture: Front Camera"*/
#define BACK_CAM_NAME							\
	"AV Capture: com.apple.avfoundation.avcapturedevice.built-in_video:0" /*"AV Capture: Back Camera"*/

NSString *const kLinphoneOldChatDBFilename = @"chat_database.sqlite";
NSString *const kLinphoneInternalChatDBFilename = @"linphone_chats.db";

@interface LinphoneManager ()
	@property(strong, nonatomic) AVAudioPlayer *messagePlayer;
@end

@implementation LinphoneManager

struct codec_name_pref_table {
	const char *name;
	int rate;
	const char *prefname;
};

struct codec_name_pref_table codec_pref_table[] = {{"speex", 8000, "speex_8k_preference"},
						   {"speex", 16000, "speex_16k_preference"},
						   {"silk", 24000, "silk_24k_preference"},
						   {"silk", 16000, "silk_16k_preference"},
						   {"amr", 8000, "amr_preference"},
						   {"gsm", 8000, "gsm_preference"},
						   {"ilbc", 8000, "ilbc_preference"},
						   {"isac", 16000, "isac_preference"},
						   {"pcmu", 8000, "pcmu_preference"},
						   {"pcma", 8000, "pcma_preference"},
						   {"g722", 8000, "g722_preference"},
						   {"g729", 8000, "g729_preference"},
						   {"mp4v-es", 90000, "mp4v-es_preference"},
						   {"h264", 90000, "h264_preference"},
						   {"h265", 90000, "h265_preference"},
						   {"vp8", 90000, "vp8_preference"},
						   {"mpeg4-generic", 16000, "aaceld_16k_preference"},
						   {"mpeg4-generic", 22050, "aaceld_22k_preference"},
						   {"mpeg4-generic", 32000, "aaceld_32k_preference"},
						   {"mpeg4-generic", 44100, "aaceld_44k_preference"},
						   {"mpeg4-generic", 48000, "aaceld_48k_preference"},
						   {"opus", 48000, "opus_preference"},
						   {"BV16", 8000, "bv16_preference"},
						   {"CODEC2", 8000, "codec2_preference"},
						   {NULL, 0, Nil}};

+ (NSString *)getPreferenceForCodec:(const char *)name withRate:(int)rate {
	int i;
	for (i = 0; codec_pref_table[i].name != NULL; ++i) {
		if (strcasecmp(codec_pref_table[i].name, name) == 0 && codec_pref_table[i].rate == rate)
			return [NSString stringWithUTF8String:codec_pref_table[i].prefname];
	}
	return Nil;
}

+ (NSSet *)unsupportedCodecs {
	NSMutableSet *set = [NSMutableSet set];
	for (int i = 0; codec_pref_table[i].name != NULL; ++i) {
		PayloadType *available = linphone_core_find_payload_type(
									 theLinphoneCore, codec_pref_table[i].name, codec_pref_table[i].rate, LINPHONE_FIND_PAYLOAD_IGNORE_CHANNELS);
		if ((available == NULL)
		    // these two codecs should not be hidden, even if not supported
		    && strcmp(codec_pref_table[i].prefname, "h264_preference") != 0 &&
		    strcmp(codec_pref_table[i].prefname, "mp4v-es_preference") != 0) {
			[set addObject:[NSString stringWithUTF8String:codec_pref_table[i].prefname]];
		}
	}
	return set;
}

+ (BOOL)isCodecSupported:(const char *)codecName {
	return (codecName != NULL) &&
		(NULL != linphone_core_find_payload_type(theLinphoneCore, codecName, LINPHONE_FIND_PAYLOAD_IGNORE_RATE,
							 LINPHONE_FIND_PAYLOAD_IGNORE_CHANNELS));
}

+ (BOOL)runningOnIpad {
	return ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);
}

+ (BOOL)isRunningTests {
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSString *injectBundle = environment[@"XCInjectBundle"];
	return [[injectBundle pathExtension] isEqualToString:@"xctest"];
}

+ (BOOL)isNotIphone3G {
	static BOOL done = FALSE;
	static BOOL result;
	if (!done) {
		size_t size;
		sysctlbyname("hw.machine", NULL, &size, NULL, 0);
		char *machine = malloc(size);
		sysctlbyname("hw.machine", machine, &size, NULL, 0);
		NSString *platform = [[NSString alloc] initWithUTF8String:machine];
		free(machine);

		result = ![platform isEqualToString:@"iPhone1,2"];

		done = TRUE;
	}
	return result;
}

+ (NSString *)getUserAgent {
	return
		[NSString stringWithFormat:@"LinphoneIphone/%@ (Linphone/%s; Apple %@/%@)",
		 [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey],
		 linphone_core_get_version(), [UIDevice currentDevice].systemName,
		 [UIDevice currentDevice].systemVersion];
}

+ (LinphoneManager *)instance {
	@synchronized(self) {
		if (theLinphoneManager == nil) {
			theLinphoneManager = [[LinphoneManager alloc] init];
		}
	}
	return theLinphoneManager;
}

#ifdef DEBUG
+ (void)instanceRelease {
	if (theLinphoneManager != nil) {
		theLinphoneManager = nil;
	}
}
#endif

+ (BOOL)langageDirectionIsRTL {
	static NSLocaleLanguageDirection dir = NSLocaleLanguageDirectionLeftToRight;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
			dir = [NSLocale characterDirectionForLanguage:[[NSLocale currentLocale] objectForKey:NSLocaleLanguageCode]];
		});
	return dir == NSLocaleLanguageDirectionRightToLeft;
}

#pragma mark - Lifecycle Functions

- (id)init {
	if ((self = [super init])) {

		NSString *path = [[NSBundle mainBundle] pathForResource:@"msg" ofType:@"wav"];
		self.messagePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:path] error:nil];

		//_sounds.vibrate = kSystemSoundID_Vibrate;

		_logs = [[NSMutableArray alloc] init];
		_pushDict = [[NSMutableDictionary alloc] init];
		_database = NULL;
		_conf = FALSE;
		_fileTransferDelegates = [[NSMutableArray alloc] init];
		_linphoneManagerAddressBookMap = [[OrderedDictionary alloc] init];
		pushCallIDs = [[NSMutableArray alloc] init];
		_isTesting = [LinphoneManager isRunningTests];
		[self migrateImportantFiles];
		[self renameDefaultSettings];
		[self copyDefaultSettings];
		[self overrideDefaultSettings];
		
		if (![self lpConfigBoolForKey:@"disable_chat_feature" withDefault:FALSE]) {
			_sounds.vibrate = kSystemSoundID_Vibrate;
		}
		
		if (![self lpConfigBoolForKey:@"migration_images_done" withDefault:FALSE]) {
			[self migrationAllImages];
		}

        [self lpConfigSetString:[LinphoneManager dataFile:@"linphone.db"] forKey:@"uri" inSection:@"storage"];
        [self lpConfigSetString:[LinphoneManager dataFile:@"x3dh.c25519.sqlite3"] forKey:@"x3dh_db_path" inSection:@"lime"];
		// set default values for first boot
		if ([self lpConfigStringForKey:@"debugenable_preference"] == nil) {
#ifdef DEBUG
			[self lpConfigSetInt:1 forKey:@"debugenable_preference"];
#else
			[self lpConfigSetInt:0 forKey:@"debugenable_preference"];
#endif
		}

		// by default if handle_content_encoding is not set, we use plain text for debug purposes only
		if ([self lpConfigStringForKey:@"handle_content_encoding" inSection:@"misc"] == nil) {
#ifdef DEBUG
			[self lpConfigSetString:@"none" forKey:@"handle_content_encoding" inSection:@"misc"];
#else
			[self lpConfigSetString:@"conflate" forKey:@"handle_content_encoding" inSection:@"misc"];
#endif
		}
        
        if ([self lpConfigStringForKey:@"display_link_account_popup"] == nil) {
            [self lpConfigSetBool:true forKey:@"display_link_account_popup"];
        }
		
		if ([self lpConfigStringForKey:@"hide_link_phone_number"] == nil) {
			[self lpConfigSetInt:1 forKey:@"hide_link_phone_number"];
		}

		[self migrateFromUserPrefs];
		[self loadAvatar];
	}
	return self;
}

- (void)dealloc {
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Contacts Updated

- (void) setContactsUpdated:(BOOL) updated{
	_contactsUpdated = updated;
}
- (BOOL) getContactsUpdated{
	return _contactsUpdated;
}

#pragma deploymate push "ignored-api-availability"
- (void)silentPushFailed:(NSTimer *)timer {
	if (_silentPushCompletion) {
		LOGI(@"silentPush failed, silentPushCompletion block: %p", _silentPushCompletion);
		_silentPushCompletion(UIBackgroundFetchResultNoData);
		_silentPushCompletion = nil;
	}
}
#pragma deploymate pop

#pragma mark - Migration

- (void)migrationAllPost {
	[self migrationLinphoneSettings];
	[self migrationPerAccount];
}

- (void)migrationAllPre {
	// migrate xmlrpc URL if needed
	if ([self lpConfigBoolForKey:@"migration_xmlrpc"] == NO) {
		[self lpConfigSetString:@"https://subscribe.linphone.org:444/wizard.php"
		 forKey:@"xmlrpc_url"
		 inSection:@"assistant"];
		[self lpConfigSetString:@"sip:rls@sip.linphone.org" forKey:@"rls_uri" inSection:@"sip"];
		[self lpConfigSetBool:YES forKey:@"migration_xmlrpc"];
	}
	[self lpConfigSetBool:NO forKey:@"store_friends" inSection:@"misc"]; //so far, storing friends in files is not needed. may change in the future.
    
}

static int check_should_migrate_images(void *data, int argc, char **argv, char **cnames) {
	*((BOOL *)data) = TRUE;
	return 0;
}

- (void)migrateFromUserPrefs {
	static NSString *migration_flag = @"userpref_migration_done";

	if (_configDb == nil)
		return;

	if ([self lpConfigIntForKey:migration_flag withDefault:0]) {
		return;
	}

	NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
	NSArray *defaults_keys = [defaults allKeys];
	NSDictionary *values =
		@{ @"backgroundmode_preference" : @NO,
		   @"debugenable_preference" : @NO,
		   @"start_at_boot_preference" : @YES };
	BOOL shouldSync = FALSE;

	LOGI(@"%lu user prefs", (unsigned long)[defaults_keys count]);

	for (NSString *userpref in values) {
		if ([defaults_keys containsObject:userpref]) {
			LOGI(@"Migrating %@ from user preferences: %d", userpref, [[defaults objectForKey:userpref] boolValue]);
			[self lpConfigSetBool:[[defaults objectForKey:userpref] boolValue] forKey:userpref];
			[[NSUserDefaults standardUserDefaults] removeObjectForKey:userpref];
			shouldSync = TRUE;
		} else if ([self lpConfigStringForKey:userpref] == nil) {
			// no default value found in our linphonerc, we need to add them
			[self lpConfigSetBool:[[values objectForKey:userpref] boolValue] forKey:userpref];
		}
	}

	if (shouldSync) {
		LOGI(@"Synchronizing...");
		[[NSUserDefaults standardUserDefaults] synchronize];
	}
	// don't get back here in the future
	[self lpConfigSetBool:YES forKey:migration_flag];
}

- (void)migrationLinphoneSettings {
	NSString *appDomain  = [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
				inSection:@"app"
				withDefault:@"sip.linphone.org"];
	
	/* AVPF migration */
	if ([self lpConfigBoolForKey:@"avpf_migration_done"] == FALSE) {
		const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
		while (accounts)
		{
			LinphoneAccount *account = (LinphoneAccount *)accounts->data;
			LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
			const char *addr = linphone_account_params_get_server_addr(newAccountParams);
			// we want to enable AVPF for the proxies
			if (addr &&
			    strstr(addr, [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
					  inSection:@"app"
					  withDefault:@"sip.linphone.org"]
				   .UTF8String) != 0) {
				LOGI(@"Migrating proxy config to use AVPF");
				linphone_account_params_set_avpf_mode(newAccountParams, LinphoneAVPFEnabled);
				linphone_account_set_params(account, newAccountParams);
			}
			accounts = accounts->next;
			linphone_account_params_unref(newAccountParams);
		}
		[self lpConfigSetBool:TRUE forKey:@"avpf_migration_done"];
	}
	/* Quality Reporting migration */
	if ([self lpConfigBoolForKey:@"quality_report_migration_done"] == FALSE) {
		const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
		while (accounts)
		{
			LinphoneAccount *account = (LinphoneAccount *)accounts->data;
			LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
			const char *addr = linphone_account_params_get_server_addr(newAccountParams);
			// we want to enable quality reporting for the proxies that are on linphone.org
			if (addr &&
			    strstr(addr, [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
					  inSection:@"app"
					  withDefault:@"sip.linphone.org"]
				   .UTF8String) != 0) {
				LOGI(@"Migrating proxy config to send quality report");
				
				linphone_account_params_set_quality_reporting_collector(
										      newAccountParams, "sip:voip-metrics@sip.linphone.org;transport=tls");
				linphone_account_params_set_quality_reporting_interval(newAccountParams, 180);
				linphone_account_params_set_quality_reporting_enabled(newAccountParams, TRUE);
				linphone_account_set_params(account, newAccountParams);
			}
			accounts = accounts->next;
			linphone_account_params_unref(newAccountParams);
		}
		[self lpConfigSetBool:TRUE forKey:@"quality_report_migration_done"];
	}
	/* File transfer migration */
	if ([self lpConfigBoolForKey:@"file_transfer_migration_done"] == FALSE) {
		const char *newURL = "https://www.linphone.org:444/lft.php";
		LOGI(@"Migrating sharing server url from %s to %s", linphone_core_get_file_transfer_server(LC), newURL);
		linphone_core_set_file_transfer_server(LC, newURL);
		[self lpConfigSetBool:TRUE forKey:@"file_transfer_migration_done"];
	}
	
	if ([self lpConfigBoolForKey:@"lime_migration_done"] == FALSE) {
		const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
		while (accounts)
		{
			if (!strcmp(linphone_account_params_get_domain(linphone_account_get_params((LinphoneAccount *)accounts->data)),"sip.linphone.org")) {
				linphone_core_set_lime_x3dh_server_url(LC, "https://lime.linphone.org/lime-server/lime-server.php");
				break;
			}
			accounts = accounts->next;
		}
		[self lpConfigSetBool:TRUE forKey:@"lime_migration_done"];
	}

	if ([self lpConfigBoolForKey:@"push_notification_migration_done"] == FALSE) {
		const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
		bool_t pushEnabled;
		while (accounts)
		{
			LinphoneAccount *account = (LinphoneAccount *)accounts->data;
			LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
			const char *refkey = linphone_account_params_get_ref_key(newAccountParams);
			if (refkey) {
				pushEnabled = (strcmp(refkey, "push_notification") == 0);
			} else {
				pushEnabled = true;
			}
			linphone_account_params_set_push_notification_allowed(newAccountParams, pushEnabled);
			linphone_account_params_set_remote_push_notification_allowed(newAccountParams, pushEnabled);
			linphone_account_set_params(account, newAccountParams);
			linphone_account_params_unref(newAccountParams);
			accounts = accounts->next;
		}
		[self lpConfigSetBool:TRUE forKey:@"push_notification_migration_done"];
	}
	if ([self lpConfigBoolForKey:@"publish_enabled_migration_done"] == FALSE) {
		const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
		linphone_core_set_log_collection_upload_server_url(LC, "https://www.linphone.org:444/lft.php");
		[self lpConfigSetBool:TRUE forKey:@"update_presence_model_timestamp_before_publish_expires_refresh"];
		
		while (accounts)
		{
			LinphoneAccount *account = (LinphoneAccount *)accounts->data;
			LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
			
			if (strcmp(appDomain.UTF8String, linphone_account_params_get_domain(newAccountParams)) == 0) {
				linphone_account_params_set_publish_enabled(newAccountParams, true);
				linphone_account_params_set_publish_expires(newAccountParams, 120);
				linphone_account_set_params(account, newAccountParams);
			}
			linphone_account_params_unref(newAccountParams);
			accounts = accounts->next;
		}
		[self lpConfigSetBool:TRUE forKey:@"publish_enabled_migration_done"];
	}
	
	linphone_core_set_video_codec_priority_policy(LC, LinphoneCodecPriorityPolicyAuto);
}

- (void)migrationPerAccount {
	const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
	NSString *appDomain  = [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
				inSection:@"app"
				withDefault:@"sip.linphone.org"];
	   while (accounts) {
		   LinphoneAccount *account = accounts->data;
		   LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
		   
		   if (strcmp(appDomain.UTF8String, linphone_account_params_get_domain(newAccountParams)) == 0) {
			   // can not create group chat without conference factory
			   if (!linphone_account_params_get_conference_factory_uri(newAccountParams)) {
				   linphone_account_params_set_conference_factory_uri(newAccountParams, "sip:conference-factory@sip.linphone.org");
				   linphone_account_set_params(account, newAccountParams);
			   }
			   
			   if (!linphone_account_params_get_audio_video_conference_factory_address(newAccountParams)) {
				   NSString *uri = [self lpConfigStringForKey:@"default_audio_video_conference_factory_uri" withDefault:@"sip:videoconference-factory2@sip.linphone.org"];
				   LinphoneAddress *a = linphone_factory_create_address(linphone_factory_get(), uri.UTF8String);
				   if (a) {
					   linphone_account_params_set_audio_video_conference_factory_address(newAccountParams, a);
					   linphone_account_set_params(account, newAccountParams);
				   }
			   }
			   
			   	/*
				if (!linphone_account_params_rtp_bundle_enabled(newAccountParams)) {
					linphone_account_params_enable_rtp_bundle(newAccountParams, true);
					linphone_account_set_params(account,newAccountParams);
			   	}
				*/
			   
			   LOGI(@"Setting the sip 'expires' parameters of existing account to 1 year (31536000 seconds)");
			   linphone_account_params_set_expires(newAccountParams, 31536000);
		   }
		   linphone_account_params_unref(newAccountParams);
		   accounts = accounts->next;
	   }
	
	NSString *s = [self lpConfigStringForKey:@"pushnotification_preference"];
	if (s && s.boolValue) {
		LOGI(@"Migrating push notification per account, enabling for ALL");
		[self lpConfigSetBool:NO forKey:@"pushnotification_preference"];
		const MSList *accounts = linphone_core_get_account_list(theLinphoneCore);
		while (accounts) {
			LinphoneAccount *account = accounts->data;
			LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
			linphone_account_params_set_push_notification_allowed(newAccountParams, true);
			linphone_account_params_set_remote_push_notification_allowed(newAccountParams, true);
			linphone_account_set_params(account, newAccountParams);
			linphone_account_params_unref(newAccountParams);
			accounts = accounts->next;
		}
	}
}

static void migrateWizardToAssistant(const char *entry, void *user_data) {
	LinphoneManager *thiz = (__bridge LinphoneManager *)(user_data);
	NSString *key = [NSString stringWithUTF8String:entry];
	[thiz lpConfigSetString:[thiz lpConfigStringForKey:key inSection:@"wizard"] forKey:key inSection:@"assistant"];
}

#pragma mark - Linphone Core Functions

+ (LinphoneCore *)getLc {
	if (theLinphoneCore == nil) {
		@throw([NSException exceptionWithName:@"LinphoneCoreException"
			reason:@"Linphone core not initialized yet"
			userInfo:nil]);
	}
	return theLinphoneCore;
}

+ (BOOL)isLcInitialized {
    if (theLinphoneCore == nil) {
        return NO;
    }
    return YES;
}

#pragma mark Debug functions

+ (void)dumpLcConfig {
	if (theLinphoneCore) {
		LpConfig *conf = LinphoneManager.instance.configDb;
		char *config = linphone_config_dump(conf);
		LOGI(@"\n%s", config);
		ms_free(config);
	}
}

#pragma mark - Logs Functions handlers
static void linphone_iphone_log_user_info(struct _LinphoneCore *lc, const char *message) {
	linphone_iphone_log_handler(NULL, ORTP_MESSAGE, message, NULL);
}
static void linphone_iphone_log_user_warning(struct _LinphoneCore *lc, const char *message) {
	linphone_iphone_log_handler(NULL, ORTP_WARNING, message, NULL);
}

#pragma mark - Display Status Functions

- (void)displayStatus:(NSString *)message {
	// Post event
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneDisplayStatusUpdate
	 object:self
	 userInfo:@{
			@"message" : message
				}];
}

static void linphone_iphone_display_status(struct _LinphoneCore *lc, const char *message) {
	NSString *status = [[NSString alloc] initWithCString:message encoding:[NSString defaultCStringEncoding]];
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) displayStatus:status];
}

#pragma mark - Call State Functions

- (void)localNotifContinue:(NSTimer *)timer {
	UILocalNotification *notif = [timer userInfo];
	if (notif) {
		LOGI(@"cancelling/presenting local notif");
		[[UIApplication sharedApplication] cancelAllLocalNotifications];
		[[UIApplication sharedApplication] presentLocalNotificationNow:notif];
	}
}

- (void)userNotifContinue:(NSTimer *)timer {
	UNNotificationContent *content = [timer userInfo];
	if (content && [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
		LOGI(@"cancelling/presenting user notif");
		UNNotificationRequest *req =
			[UNNotificationRequest requestWithIdentifier:@"call_request" content:content trigger:NULL];
		[[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req
		 withCompletionHandler:^(NSError *_Nullable error) {
				// Enable or disable features based on authorization.
				if (error) {
					LOGD(@"Error while adding notification request :");
					LOGD(error.description);
				}
			}];
	}
}

#pragma mark - Ephemeral State Functions
static void linphone_iphone_ephemeral_message_deleted(LinphoneCore *lc, LinphoneChatRoom *cr) {
	LinphoneManager *lm = (__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc));
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:[NSValue valueWithPointer:cr], @"room", nil];
	
	// dispatch the notification asynchronously
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneEphemeralMessageDeletedInRoom object:lm userInfo:dict];
	});
	
}

#pragma mark - Transfert State Functions

static void linphone_iphone_transfer_state_changed(LinphoneCore *lc, LinphoneCall *call, LinphoneCallState state) {
}

#pragma mark - Global state change

static void linphone_iphone_global_state_changed(LinphoneCore *lc, LinphoneGlobalState gstate, const char *message) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onGlobalStateChanged:gstate withMessage:message];
}

- (void)onGlobalStateChanged:(LinphoneGlobalState)state withMessage:(const char *)message {
	LOGI(@"onGlobalStateChanged: %d (message: %s)", state, message);

	NSDictionary *dict = [NSDictionary
			      dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:state], @"state",
			      [NSString stringWithUTF8String:message ? message : ""], @"message", nil];
	// dispatch the notification asynchronously
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		if (theLinphoneCore && linphone_core_get_global_state(theLinphoneCore) != LinphoneGlobalOff)
			[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneGlobalStateUpdate object:self userInfo:dict];
	});
	
	if (state == LinphoneGlobalOn) {
		// reload friends
		[self.fastAddressBook fetchContactsInBackGroundThread];
		/*if (@available(iOS 15.0, *)) {
			[LocalPushManager.shared configureLocalPushWithCCoreConfig:linphone_core_get_config(LC)];
		} else {
			LOGW(@"Local push notifications not available for this ios version (iOS 15 minimum)");
		}*/
	}
}

- (void)globalStateChangedNotificationHandler:(NSNotification *)notif {
	if ((LinphoneGlobalState)[[[notif userInfo] valueForKey:@"state"] integerValue] == LinphoneGlobalOn) {
		[self finishCoreConfiguration];
	}
}

#pragma mark - Configuring status changed

static void linphone_iphone_configuring_status_changed(LinphoneCore *lc, LinphoneConfiguringState status,
						       const char *message) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onConfiguringStatusChanged:status withMessage:message];
}

- (void)onConfiguringStatusChanged:(LinphoneConfiguringState)status withMessage:(const char *)message {
	LOGI(@"onConfiguringStatusChanged: %s %@", linphone_configuring_state_to_string(status),
	     message ? [NSString stringWithFormat:@"(message: %s)", message] : @"");
	NSDictionary *dict = [NSDictionary
			      dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:status], @"state",
			      [NSString stringWithUTF8String:message ? message : ""], @"message", nil];

	// dispatch the notification asynchronously
	dispatch_async(dispatch_get_main_queue(), ^(void) {
			[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneConfiguringStateUpdate
			 object:self
			 userInfo:dict];
		});
	
	if (status == LinphoneConfiguringSuccessful) {
		/*if (@available(iOS 15.0, *)) {
			[LocalPushManager.shared configureLocalPushWithCCoreConfig:linphone_core_get_config(LC)];
		} else {
			LOGW(@"Local push notifications not available for this ios version (iOS 15 minimum)");
		}*/
	}
}

#pragma mark - Registration State Functions

- (void)onRegister:(LinphoneCore *)lc
account:(LinphoneAccount *)account
state:(LinphoneRegistrationState)state
message:(const char *)cmessage {
	LOGI(@"New registration state: %s (message: %s)", linphone_registration_state_to_string(state), cmessage);

	LinphoneReason reason = linphone_account_get_error(account);
	NSString *message = nil;
	switch (reason) {
	case LinphoneReasonBadCredentials:
		message = NSLocalizedString(@"Bad credentials, check your account settings", nil);
		break;
	case LinphoneReasonNoResponse:
		message = NSLocalizedString(@"No response received from remote", nil);
		break;
	case LinphoneReasonUnsupportedContent:
		message = NSLocalizedString(@"Unsupported content", nil);
		break;
	case LinphoneReasonIOError:
		message = NSLocalizedString(
					    @"Cannot reach the server: either it is an invalid address or it may be temporary down.", nil);
		break;

	case LinphoneReasonUnauthorized:
		message = NSLocalizedString(@"Operation is unauthorized because missing credential", nil);
		break;
	case LinphoneReasonNoMatch:
		message = NSLocalizedString(@"Operation could not be executed by server or remote client because it "
					    @"didn't have any context for it",
					    nil);
		break;
	case LinphoneReasonMovedPermanently:
		message = NSLocalizedString(@"Resource moved permanently", nil);
		break;
	case LinphoneReasonGone:
		message = NSLocalizedString(@"Resource no longer exists", nil);
		break;
	case LinphoneReasonTemporarilyUnavailable:
		message = NSLocalizedString(@"Temporarily unavailable", nil);
		break;
	case LinphoneReasonAddressIncomplete:
		message = NSLocalizedString(@"Address incomplete", nil);
		break;
	case LinphoneReasonNotImplemented:
		message = NSLocalizedString(@"Not implemented", nil);
		break;
	case LinphoneReasonBadGateway:
		message = NSLocalizedString(@"Bad gateway", nil);
		break;
	case LinphoneReasonServerTimeout:
		message = NSLocalizedString(@"Server timeout", nil);
		break;
	case LinphoneReasonNotAcceptable:
	case LinphoneReasonDoNotDisturb:
	case LinphoneReasonDeclined:
	case LinphoneReasonNotFound:
	case LinphoneReasonNotAnswered:
	case LinphoneReasonBusy:
	case LinphoneReasonNone:
	case LinphoneReasonUnknown:
		message = NSLocalizedString(@"Unknown error", nil);
		break;
	}

	// Post event
	NSDictionary *dict =
		[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:state], @"state",
		 [NSValue valueWithPointer:account], @"account", message, @"message", nil];
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneRegistrationUpdate object:self userInfo:dict];
}

static void linphone_iphone_registration_state(LinphoneCore *lc, LinphoneAccount *account,
					       LinphoneRegistrationState state, const char *message) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onRegister:lc account:account state:state message:message];
}

#pragma mark - Auth info Function

static void linphone_iphone_popup_password_request(LinphoneCore *lc, LinphoneAuthInfo *auth_info, LinphoneAuthMethod method) {
	// let the wizard handle its own errors
	if ([PhoneMainView.instance currentView] != AssistantView.compositeViewDescription) {
		const char * realmC = linphone_auth_info_get_realm(auth_info);
		const char * usernameC = linphone_auth_info_get_username(auth_info) ? : "";
		const char * domainC = linphone_auth_info_get_domain(auth_info) ? : "";
		static UIAlertController *alertView = nil;
		
		// InstantMessageDeliveryNotifications from previous accounts can trigger some pop-up spam asking for indentification
		// Try to filter the popup password request to avoid displaying those that do not matter and can be handled through a simple warning
		const MSList *accountList = linphone_core_get_account_list(LC);
		bool foundMatchingConfig = false;
		while (accountList && !foundMatchingConfig) {
			LinphoneAccountParams const *accountParams = linphone_account_get_params(accountList->data);
			const char * configUsername = linphone_address_get_username(linphone_account_params_get_identity_address(accountParams));
			const char * configDomain = linphone_account_params_get_domain(accountParams);
			foundMatchingConfig = (strcmp(configUsername, usernameC) == 0) && (strcmp(configDomain, domainC) == 0);
			accountList = accountList->next;
		}
		if (!foundMatchingConfig) {
			LOGW(@"Received an authentication request from %s@%s, but ignored it did not match any current user", usernameC, domainC);
			return;
		}
		
		// avoid having multiple popups
		[PhoneMainView.instance dismissViewControllerAnimated:YES completion:nil];

		// dont pop up if we are in background, in any case we will refresh registers when entering
		// the application again
		if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
			return;
		}

		NSString *realm = [NSString stringWithUTF8String:realmC?:domainC];
		NSString *username = [NSString stringWithUTF8String:usernameC];
		NSString *domain = [NSString stringWithUTF8String:domainC];
		alertView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Authentification needed", nil)
			     message:[NSString stringWithFormat:NSLocalizedString(@"Connection failed because authentication is "
										  @"missing or invalid for %@@%@.\nYou can "
										  @"provide password again, or check your "
										  @"account configuration in the settings.", nil), username, realm]
			     preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
						style:UIAlertActionStyleDefault
						handler:^(UIAlertAction * action) {}];

		[alertView addTextFieldWithConfigurationHandler:^(UITextField *textField) {
				textField.placeholder = NSLocalizedString(@"Password", nil);
				textField.clearButtonMode = UITextFieldViewModeWhileEditing;
				textField.borderStyle = UITextBorderStyleRoundedRect;
				textField.secureTextEntry = YES;
			}];

		UIAlertAction* continueAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Confirm password", nil)
						 style:UIAlertActionStyleDefault
						 handler:^(UIAlertAction * action) {
				NSString *password = alertView.textFields[0].text;
				LinphoneAuthInfo *info =
				linphone_auth_info_new(username.UTF8String, NULL, password.UTF8String, NULL,
						       realm.UTF8String, domain.UTF8String);
				linphone_core_add_auth_info(LC, info);
				[LinphoneManager.instance refreshRegisters];
			}];

		UIAlertAction* settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Go to settings", nil)
						 style:UIAlertActionStyleDefault
						 handler:^(UIAlertAction * action) {
				[PhoneMainView.instance changeCurrentView:SettingsView.compositeViewDescription];
			}];

		[alertView addAction:defaultAction];
		[alertView addAction:continueAction];
		[alertView addAction:settingsAction];
		[PhoneMainView.instance presentViewController:alertView animated:YES completion:nil];
	}
}

#pragma mark - Text Received Functions

- (void)onMessageReceived:(LinphoneCore *)lc room:(LinphoneChatRoom *)room message:(LinphoneChatMessage *)msg {
#pragma deploymate push "ignored-api-availability"
	if (_silentPushCompletion) {
		// we were woken up by a silent push. Call the completion handler with NEWDATA
		// so that the push is notified to the user
		LOGI(@"onMessageReceived - handler %p", _silentPushCompletion);
		_silentPushCompletion(UIBackgroundFetchResultNewData);
		_silentPushCompletion = nil;
	}
#pragma deploymate pop
	NSString *callID = [NSString stringWithUTF8String:linphone_chat_message_get_custom_header(msg, "Call-ID")];

	int index = [(NSNumber *)[_pushDict objectForKey:callID] intValue] - 1;
	LOGI(@"Decrementing index of long running task for call id : %@ with index : %d", callID, index);
	[_pushDict setValue:[NSNumber numberWithInt:index] forKey:callID];
	BOOL need_bg_task = FALSE;
	for (NSString *key in [_pushDict allKeys]) {
		int value = [(NSNumber *)[_pushDict objectForKey:key] intValue];
		if (value > 0) {
			need_bg_task = TRUE;
			break;
		}
	}
	if (pushBgTaskMsg && !need_bg_task) {
		LOGI(@"Message received, stopping message background task for call-id [%@]", callID);
		[[UIApplication sharedApplication] endBackgroundTask:pushBgTaskMsg];
		pushBgTaskMsg = 0;
	}
    
	BOOL hasFile = FALSE;
	// if auto_download is available and file is downloaded
	if ((linphone_core_get_max_size_for_auto_download_incoming_files(LC) > -1) && linphone_chat_message_get_file_transfer_information(msg))
		hasFile = TRUE;

	if (!linphone_chat_message_is_file_transfer(msg) && !linphone_chat_message_is_text(msg) && !hasFile  && ![ICSBubbleView isConferenceInvitationMessageWithCmessage:msg])
		return;
    
	if (hasFile) {
		if (PhoneMainView.instance.currentView == ChatConversationViewSwift.compositeViewDescription && room == PhoneMainView.instance.currentRoom)
			return;
		[self autoDownload:msg];
	}

	// Post event
	NSDictionary *dict = @{
		@"room" : [NSValue valueWithPointer:room],
		@"from_address" : [NSValue valueWithPointer:linphone_chat_message_get_from_address(msg)],
		@"message" : [NSValue valueWithPointer:msg],
		@"call-id" : callID
	};

	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneMessageReceived object:self userInfo:dict];
}

- (void)autoDownload:(LinphoneChatMessage *)message {
	LinphoneContent *content = linphone_chat_message_get_file_transfer_information(message);
	NSString *name = [NSString stringWithUTF8String:linphone_content_get_name(content)];
	NSString *fileType = [NSString stringWithUTF8String:linphone_content_get_type(content)];
	NSString *key = [ChatConversationViewSwift getKeyFromFileType:fileType fileName:name];

	[LinphoneManager setValueInMessageAppData:name forKey:key inMessage:message];
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneMessageReceived object:VIEW(ChatConversationViewSwift)];
		if (![VFSUtil vfsEnabledWithGroupName:kLinphoneMsgNotificationAppGroupId] && [ConfigManager.instance lpConfigBoolForKeyWithKey:@"auto_write_to_gallery_preference"]) {
			[ChatConversationViewSwift writeMediaToGalleryFromName:name fileType:fileType];
		}
	});
}

static void linphone_iphone_message_received(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatMessage *message) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onMessageReceived:lc room:room message:message];
}

static void linphone_iphone_message_received_unable_decrypt(LinphoneCore *lc, LinphoneChatRoom *room,
							    LinphoneChatMessage *message) {
}

- (void)onNotifyReceived:(LinphoneCore *)lc
event:(LinphoneEvent *)lev
notifyEvent:(const char *)notified_event
content:(const LinphoneContent *)body {
	// Post event
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	[dict setObject:[NSValue valueWithPointer:lev] forKey:@"event"];
	[dict setObject:[NSString stringWithUTF8String:notified_event] forKey:@"notified_event"];
	if (body != NULL) {
		[dict setObject:[NSValue valueWithPointer:body] forKey:@"content"];
	}
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneNotifyReceived object:self userInfo:dict];
}

static void linphone_iphone_notify_received(LinphoneCore *lc, LinphoneEvent *lev, const char *notified_event,
					    const LinphoneContent *body) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onNotifyReceived:lc
	 event:lev
	 notifyEvent:notified_event
	 content:body];
}

- (void)onNotifyPresenceReceivedForUriOrTel:(LinphoneCore *)lc
friend:(LinphoneFriend *)lf
uri:(const char *)uri
presenceModel:(const LinphonePresenceModel *)model {
	// Post event
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	[dict setObject:[NSValue valueWithPointer:lf] forKey:@"friend"];
	[dict setObject:[NSValue valueWithPointer:uri] forKey:@"uri"];
	[dict setObject:[NSValue valueWithPointer:model] forKey:@"presence_model"];
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneNotifyPresenceReceivedForUriOrTel
	 object:self
	 userInfo:dict];
}

static void linphone_iphone_notify_presence_received_for_uri_or_tel(LinphoneCore *lc, LinphoneFriend *lf,
								    const char *uri_or_tel,
								    const LinphonePresenceModel *presence_model) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onNotifyPresenceReceivedForUriOrTel:lc
	 friend:lf
	 uri:uri_or_tel
	 presenceModel:presence_model];
}

static void linphone_iphone_call_encryption_changed(LinphoneCore *lc, LinphoneCall *call, bool_t on,
						    const char *authentication_token) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onCallEncryptionChanged:lc
	 call:call
	 on:on
	 token:authentication_token];
}

- (void)onCallEncryptionChanged:(LinphoneCore *)lc
call:(LinphoneCall *)call
on:(BOOL)on
token:(const char *)authentication_token {
	// Post event
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	[dict setObject:[NSValue valueWithPointer:call] forKey:@"call"];
	[dict setObject:[NSNumber numberWithBool:on] forKey:@"on"];
	if (authentication_token) {
		[dict setObject:[NSString stringWithUTF8String:authentication_token] forKey:@"token"];
	}
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneCallEncryptionChanged object:self userInfo:dict];
}

void linphone_iphone_chatroom_state_changed(LinphoneCore *lc, LinphoneChatRoom *cr, LinphoneChatRoomState state) {
    if (state == LinphoneChatRoomStateCreated) {
        [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneMessageReceived object:nil];
    }
}

void linphone_iphone_version_update_check_result_received (LinphoneCore *lc, LinphoneVersionUpdateCheckResult result, const char *version, const char *url) {
	if (result == LinphoneVersionUpdateCheckUpToDate || result == LinphoneVersionUpdateCheckError) {
		return;
	}
	NSString *title = NSLocalizedString(@"Outdated Version", nil);
	NSString *body = NSLocalizedString(@"A new version of your app is available, use the button below to download it.", nil);

	UIAlertController *versVerifView = [UIAlertController alertControllerWithTitle:title
					    message:body
					    preferredStyle:UIAlertControllerStyleAlert];

	NSString *ObjCurl = [NSString stringWithUTF8String:url];
	UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Download", nil)
					style:UIAlertActionStyleDefault
					handler:^(UIAlertAction * action) {
			[[UIApplication sharedApplication] openURL:[NSURL URLWithString:ObjCurl]];
		}];

	[versVerifView addAction:defaultAction];
	[PhoneMainView.instance presentViewController:versVerifView animated:YES completion:nil];
}

void linphone_iphone_qr_code_found(LinphoneCore *lc, const char *result) {
	NSDictionary *eventDic = [NSDictionary dictionaryWithObject:[NSString stringWithCString:result encoding:[NSString defaultCStringEncoding]] forKey:@"qrcode"];
	LOGD(@"QRCODE FOUND");
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneQRCodeFound object:nil userInfo:eventDic];
}

static void linphone_iphone_call_log_updated(LinphoneCore *lc, LinphoneCallLog *newcl) {
	if (linphone_call_log_get_status(newcl) == LinphoneCallEarlyAborted) {
		const char *cid = linphone_call_log_get_call_id(newcl);
		if (cid) {
			[CallManager.instance markCallAsDeclinedWithCallId:[NSString stringWithUTF8String:cid]];
		}
	}
}

static void linphone_iphone_call_id_updated(LinphoneCore *lc, const char *previous_call_id, const char *current_call_id) {
	[CallManager.instance updateCallIdWithPrevious:[NSString stringWithUTF8String:previous_call_id] current:[NSString stringWithUTF8String:current_call_id]];
}
#pragma mark - Message composition start
- (void)onMessageComposeReceived:(LinphoneCore *)core forRoom:(LinphoneChatRoom *)room {
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneTextComposeEvent
	 object:self
	 userInfo:@{
			@"room" : [NSValue valueWithPointer:room]
				}];
}

static void linphone_iphone_is_composing_received(LinphoneCore *lc, LinphoneChatRoom *room) {
	[(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onMessageComposeReceived:lc forRoom:room];
}

#pragma mark - Network Functions


- (NetworkType)network {
	if ([[[UIDevice currentDevice] systemVersion] floatValue] < 7) {
		UIApplication *app = [UIApplication sharedApplication];
		NSArray *subviews = [[[app valueForKey:@"statusBar"] valueForKey:@"foregroundView"] subviews];
		NSNumber *dataNetworkItemView = nil;

		for (id subview in subviews) {
			if ([subview isKindOfClass:[NSClassFromString(@"UIStatusBarDataNetworkItemView") class]]) {
				dataNetworkItemView = subview;
				break;
			}
		}

		NSNumber *number = (NSNumber *)[dataNetworkItemView valueForKey:@"dataNetworkType"];
		return [number intValue];
	} else {
#pragma deploymate push "ignored-api-availability"
		CTTelephonyNetworkInfo *info = [[CTTelephonyNetworkInfo alloc] init];
		NSString *currentRadio = info.currentRadioAccessTechnology;
		if ([currentRadio isEqualToString:CTRadioAccessTechnologyEdge]) {
			return network_2g;
		} else if ([currentRadio isEqualToString:CTRadioAccessTechnologyLTE]) {
			return network_4g;
		}
#pragma deploymate pop
		return network_3g;
	}
}

- (void)setDnsServer {
	NSString *dns_server_ip = [self lpConfigStringForKey:@"dns_server_ip"];
	if ([dns_server_ip isEqualToString:@""]) {dns_server_ip = NULL;}
	bctbx_list_t *dns_server_list = dns_server_ip?bctbx_list_new((void *)[dns_server_ip UTF8String]):NULL;
	linphone_core_set_dns_servers_app(LC, dns_server_list);
	bctbx_list_free(dns_server_list);
}

#pragma mark -

// scheduling loop
- (void)iterate {
	linphone_core_iterate(theLinphoneCore);
}

/** Should be called once per linphone_core_new() */
- (void)finishCoreConfiguration {
	//Force keep alive to workaround push notif on chat message
	linphone_core_enable_keep_alive([LinphoneManager getLc], true);

	// get default config from bundle
	NSString *zrtpSecretsFileName = [LinphoneManager dataFile:@"zrtp_secrets"];
	NSString *chatDBFileName = [LinphoneManager dataFile:kLinphoneInternalChatDBFilename];
	NSString *device = [[NSMutableString alloc] initWithString:[NSString stringWithFormat:@"%@iOS/%@ (%@) LinphoneSDK",
								    [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"],
								    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
								    [[UIDevice currentDevice] name]]];

	linphone_core_set_user_agent(theLinphoneCore, device.UTF8String, LINPHONE_SDK_VERSION);

	_contactSipField = [self lpConfigStringForKey:@"contact_im_type_value" inSection:@"sip" withDefault:@"SIP"];

	if (_fastAddressBook == nil) {
		_fastAddressBook = [[FastAddressBook alloc] init];
	}

	linphone_core_set_zrtp_secrets_file(theLinphoneCore, [zrtpSecretsFileName UTF8String]);
	//linphone_core_set_chat_database_path(theLinphoneCore, [chatDBFileName UTF8String]);
	linphone_core_set_call_logs_database_path(theLinphoneCore, [chatDBFileName UTF8String]);

	NSString *path = [LinphoneManager bundleFile:@"nowebcamCIF.jpg"];
	if (path) {
		const char *imagePath = [path UTF8String];
		LOGI(@"Using '%s' as source image for no webcam", imagePath);
		linphone_core_set_static_picture(theLinphoneCore, imagePath);
	}

	/*DETECT cameras*/
	_frontCamId = _backCamId = nil;
	char **camlist = (char **)linphone_core_get_video_devices(theLinphoneCore);
	if (camlist) {
		for (char *cam = *camlist; *camlist != NULL; cam = *++camlist) {
			if (strcmp(FRONT_CAM_NAME, cam) == 0) {
				_frontCamId = cam;
				// great set default cam to front
				LOGI(@"Setting default camera [%s]", _frontCamId);
				linphone_core_set_video_device(theLinphoneCore, _frontCamId);
			}
			if (strcmp(BACK_CAM_NAME, cam) == 0) {
				_backCamId = cam;
			}
		}
	} else {
		LOGW(@"No camera detected!");
	}

	if (![LinphoneManager isNotIphone3G]) {
		PayloadType *pt = linphone_core_find_payload_type(theLinphoneCore, "SILK", 24000, -1);
		if (pt) {
			linphone_core_enable_payload_type(theLinphoneCore, pt, FALSE);
			LOGW(@"SILK/24000 and video disabled on old iPhone 3G");
		}
		linphone_core_enable_video_display(theLinphoneCore, FALSE);
		linphone_core_enable_video_capture(theLinphoneCore, FALSE);
	}

	[self enableProxyPublish:([UIApplication sharedApplication].applicationState == UIApplicationStateActive)];

	LOGI(@"Linphone [%s] started on [%s]", linphone_core_get_version(), [[UIDevice currentDevice].model UTF8String]);

	// Post event
	NSDictionary *dict = [NSDictionary dictionaryWithObject:[NSValue valueWithPointer:theLinphoneCore] forKey:@"core"];

	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneCoreUpdate
	 object:LinphoneManager.instance
	 userInfo:dict];

	
}

static BOOL libStarted = FALSE;

- (void)launchLinphoneCore {

	if (libStarted) {
		LOGE(@"Liblinphone is already initialized!");
		return;
	}

	libStarted = TRUE;

	signal(SIGPIPE, SIG_IGN);

	// create linphone core
	[self createLinphoneCore];
	_iapManager = [[InAppProductsManager alloc] init];

	// - Security fix - remove multi transport migration, because it enables tcp or udp, if by factoring settings only
	// tls is enabled. 	This is a problem for new installations.
	// linphone_core_migrate_to_multi_transport(theLinphoneCore);

	// init audio session (just getting the instance will init)
	AVAudioSession *audioSession = [AVAudioSession sharedInstance];
	BOOL bAudioInputAvailable = audioSession.inputAvailable;
	NSError *err = nil;

	if (![audioSession setActive:NO error:&err] && err) {
		LOGE(@"audioSession setActive failed: %@", [err description]);
		err = nil;
	}
	if (!bAudioInputAvailable) {
		UIAlertController *errView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"No microphone", nil)
					      message:NSLocalizedString(@"You need to plug a microphone to your device to use the application.", nil)
					      preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
						style:UIAlertActionStyleDefault
						handler:^(UIAlertAction * action) {}];

		[errView addAction:defaultAction];
		[PhoneMainView.instance presentViewController:errView animated:YES completion:nil];
	}

	if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
		// go directly to bg mode
		[self enterBackgroundMode];
	}
	
	
}

void popup_link_account_cb(LinphoneAccountCreator *creator, LinphoneAccountCreatorStatus status, const char *resp) {
	if (status == LinphoneAccountCreatorStatusAccountLinked) {
		[LinphoneManager.instance lpConfigSetInt:0 forKey:@"must_link_account_time"];
	} else {
		LinphoneAccount *account = linphone_core_get_default_account(LC);
		LinphoneAccountParams const *accountParams = account ? linphone_account_get_params(account) : NULL;
		if (account &&
		    strcmp(linphone_account_params_get_domain(accountParams),
			   [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
			    inSection:@"app"
			    withDefault:@"sip.linphone.org"]
			   .UTF8String) == 0) {
			UIAlertController *errView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Link your account", nil)
						      message:[NSString stringWithFormat:NSLocalizedString(@"Link your Linphone.org account %s to your phone number.", nil),
							       linphone_address_get_username(linphone_account_params_get_identity_address(accountParams))]
						      preferredStyle:UIAlertControllerStyleAlert];

			UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Maybe later", nil)
							style:UIAlertActionStyleDefault
							handler:^(UIAlertAction * action) {}];

			UIAlertAction* continueAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Let's go", nil)
							 style:UIAlertActionStyleDefault
							 handler:^(UIAlertAction * action) {
					[PhoneMainView.instance changeCurrentView:AssistantLinkView.compositeViewDescription];
				}];
                   
            UIAlertAction* otherAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Never ask again", nil)
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction * action) {
                [LinphoneManager.instance lpConfigSetBool:false forKey:@"display_link_account_popup"];
            }];
			defaultAction.accessibilityLabel = @"Later";
            [errView addAction:otherAction];
			[errView addAction:defaultAction];
			[errView addAction:continueAction];
			[PhoneMainView.instance presentViewController:errView animated:YES completion:nil];

			[LinphoneManager.instance
			 lpConfigSetInt:[[NSDate date] dateByAddingTimeInterval:[LinphoneManager.instance
										 lpConfigIntForKey:@"link_account_popup_time"
										 withDefault:84200]]
			 .timeIntervalSince1970
			 forKey:@"must_link_account_time"];
		}
	}
}

- (void)shouldPresentLinkPopup {
	NSDate *nextTime =
		[NSDate dateWithTimeIntervalSince1970:[self lpConfigIntForKey:@"must_link_account_time" withDefault:1]];
	NSDate *now = [NSDate date];
    if (nextTime.timeIntervalSince1970 > 0 && [now earlierDate:nextTime] == nextTime && [LinphoneManager.instance lpConfigBoolForKey:@"display_link_account_popup"] && ![LinphoneManager.instance lpConfigIntForKey:@"hide_link_phone_number"]) {
		LinphoneAccount *account = linphone_core_get_default_account(LC);
		if (account) {
			const char *username = linphone_address_get_username(linphone_account_params_get_identity_address(linphone_account_get_params(account)));
			LinphoneAccountCreator *account_creator = linphone_account_creator_new(
											       LC,
											       [LinphoneManager.instance lpConfigStringForKey:@"xmlrpc_url" inSection:@"assistant" withDefault:@""]
											       .UTF8String);
			linphone_account_creator_set_user_data(account_creator, (__bridge void *)(self));
			linphone_account_creator_cbs_set_is_account_linked(linphone_account_creator_get_callbacks(account_creator),
									   popup_link_account_cb);
			linphone_account_creator_set_username(account_creator, username);
			linphone_account_creator_is_account_linked(account_creator);
		}
	}
}

- (void)configurePushProviderForAccounts {
	const MSList *accountsList = linphone_core_get_account_list(theLinphoneCore);
	while (accountsList) {
		LinphoneAccount * account = accountsList->data;
		LinphoneAccountParams * accountParams = linphone_account_params_clone(linphone_account_get_params(account));
		// In linphone-iphone, remote and voip push autorisations always go together.
		bool accountPushAllowed = linphone_account_params_get_push_notification_allowed(accountParams);
		linphone_account_params_set_remote_push_notification_allowed(accountParams, accountPushAllowed);
		
		
		LinphonePushNotificationConfig *pushConfig = linphone_account_params_get_push_notification_config(accountParams);
#ifdef DEBUG
#define PROVIDER_NAME "apns.dev"
#else
#define PROVIDER_NAME "apns"
#endif
		linphone_push_notification_config_set_provider(pushConfig, PROVIDER_NAME);
		linphone_account_set_params(account, accountParams);
		linphone_account_params_unref(accountParams);
		accountsList = accountsList->next;
	}
}

- (void)enableLinphoneAccountSpecificSettings {
	const MSList *accountsList = linphone_core_get_account_list(theLinphoneCore);
	while (accountsList) {
		LinphoneAccount * account = accountsList->data;
		LinphoneAccountParams const * currentParams = linphone_account_get_params(account);
		LinphoneAddress const * currentAddress = linphone_account_params_get_identity_address(currentParams);
		char * addressIdentity = linphone_address_as_string(currentAddress);
		
		if (strcmp(linphone_address_get_domain(currentAddress), "sip.linphone.org") == 0) {
			LinphoneAccountParams * newParams = linphone_account_params_clone(linphone_account_get_params(account));
			if  (!linphone_account_params_cpim_in_basic_chat_room_enabled(currentParams) ) {
				LOGI(@"Enabling CPIM in basic chatroom for account [%s]", addressIdentity);
				linphone_account_params_enable_cpim_in_basic_chat_room(newParams, true);
			}
			
			const char* current_lime_url = linphone_account_params_get_lime_server_url(currentParams);
			if (!current_lime_url){
				const char* core_lime_url = linphone_core_get_lime_x3dh_server_url(LC);
				if (core_lime_url) {
					LOGI(@"Copying core's LIME X3DH server URL [%s] to account [%s]", core_lime_url, addressIdentity);
					linphone_account_params_set_lime_server_url(newParams, core_lime_url);
				} else {
					LOGI(@"Account [%s] didn't have a LIME X3DH server URL, setting one: [%s]", addressIdentity, core_lime_url);
					linphone_account_params_set_lime_server_url(newParams, "https://lime.linphone.org/lime-server/lime-server.php");
				}
			}
			linphone_account_set_params(account, newParams);
			linphone_account_params_unref(newParams);
		}
		
		ms_free(addressIdentity);
		accountsList = accountsList->next;
	}
}

- (void)startLinphoneCore {
	bool corePushEnabled = [self lpConfigIntForKey:@"net" inSection:@"push_notification"];
	linphone_core_set_push_notification_enabled([LinphoneManager getLc], corePushEnabled);
	linphone_core_start([LinphoneManager getLc]);
	
	[self configurePushProviderForAccounts];
	[self enableLinphoneAccountSpecificSettings];
}

- (void)createLinphoneCore {
	[self migrationAllPre];
	if (theLinphoneCore != nil) {
		LOGI(@"linphonecore is already created");
		return;
	}


	// Set audio assets
	NSString *ring =
		([LinphoneManager bundleFile:[self lpConfigStringForKey:@"local_ring" inSection:@"sound"].lastPathComponent]
		 ?: [LinphoneManager bundleFile:@"notes_of_the_optimistic.caf"])
		.lastPathComponent;
	NSString *ringback =
		([LinphoneManager bundleFile:[self lpConfigStringForKey:@"remote_ring" inSection:@"sound"].lastPathComponent]
		 ?: [LinphoneManager bundleFile:@"ringback.wav"])
		.lastPathComponent;
	NSString *hold =
		([LinphoneManager bundleFile:[self lpConfigStringForKey:@"hold_music" inSection:@"sound"].lastPathComponent]
		 ?: [LinphoneManager bundleFile:@"hold.mkv"])
		.lastPathComponent;
	[self lpConfigSetString:[LinphoneManager bundleFile:ring] forKey:@"local_ring" inSection:@"sound"];
	[self lpConfigSetString:[LinphoneManager bundleFile:ringback] forKey:@"remote_ring" inSection:@"sound"];
	[self lpConfigSetString:[LinphoneManager bundleFile:hold] forKey:@"hold_music" inSection:@"sound"];

	LinphoneFactory *factory = linphone_factory_get();
	LinphoneCoreCbs *cbs = linphone_factory_create_core_cbs(factory);
	linphone_core_cbs_set_account_registration_state_changed(cbs,linphone_iphone_registration_state);
	linphone_core_cbs_set_notify_presence_received_for_uri_or_tel(cbs, linphone_iphone_notify_presence_received_for_uri_or_tel);
	linphone_core_cbs_set_authentication_requested(cbs, linphone_iphone_popup_password_request);
	linphone_core_cbs_set_message_received(cbs, linphone_iphone_message_received);
	linphone_core_cbs_set_message_received_unable_decrypt(cbs, linphone_iphone_message_received_unable_decrypt);
	linphone_core_cbs_set_transfer_state_changed(cbs, linphone_iphone_transfer_state_changed);
	linphone_core_cbs_set_is_composing_received(cbs, linphone_iphone_is_composing_received);
	linphone_core_cbs_set_configuring_status(cbs, linphone_iphone_configuring_status_changed);
	linphone_core_cbs_set_global_state_changed(cbs, linphone_iphone_global_state_changed);
	linphone_core_cbs_set_notify_received(cbs, linphone_iphone_notify_received);
	linphone_core_cbs_set_call_encryption_changed(cbs, linphone_iphone_call_encryption_changed);
	linphone_core_cbs_set_chat_room_state_changed(cbs, linphone_iphone_chatroom_state_changed);
	linphone_core_cbs_set_version_update_check_result_received(cbs, linphone_iphone_version_update_check_result_received);
	linphone_core_cbs_set_qrcode_found(cbs, linphone_iphone_qr_code_found);
	linphone_core_cbs_set_call_log_updated(cbs, linphone_iphone_call_log_updated);
	linphone_core_cbs_set_call_id_updated(cbs, linphone_iphone_call_id_updated);
	linphone_core_cbs_set_user_data(cbs, (__bridge void *)(self));
	linphone_core_cbs_set_chat_room_ephemeral_message_deleted(cbs, linphone_iphone_ephemeral_message_deleted);
	linphone_core_cbs_set_conference_state_changed(cbs, linphone_iphone_conference_state_changed);


	bool reEnableRls = false;
	if (![LinphoneManager.instance lpConfigBoolForKey:@"use_rls_presence_requested"] && [LinphoneManager.instance lpConfigBoolForKey:@"use_rls_presence"]) {
		[LinphoneManager.instance lpConfigSetBool:false forKey:@"use_rls_presence"];
		reEnableRls = true;
	}

	theLinphoneCore = linphone_factory_create_shared_core_with_config(factory, _configDb, NULL, [kLinphoneMsgNotificationAppGroupId UTF8String], true);
	
	if (bctbx_list_size(linphone_core_get_account_list(theLinphoneCore)) > 0 && reEnableRls) { // Do not request rls allowance for users who had it before.
		[LinphoneManager.instance lpConfigSetBool:true forKey:@"use_rls_presence"];
	}
	
	linphone_core_enable_auto_iterate(theLinphoneCore, true);
	linphone_core_set_chat_messages_aggregation_enabled(theLinphoneCore, false);
	linphone_core_add_callbacks(theLinphoneCore, cbs);

	[ConfigManager.instance setDbWithDb:_configDb];
	[CallManager.instance setCoreWithCore:theLinphoneCore];
	[CallsViewModelBridge updateCore];
	
	[LinphoneManager.instance startLinphoneCore];

	// Let the core handle cbs
	linphone_core_cbs_unref(cbs);

	LOGI(@"Create linphonecore %p", theLinphoneCore);

	// Load plugins if available in the linphone SDK - otherwise these calls will do nothing
	MSFactory *f = linphone_core_get_ms_factory(theLinphoneCore);
	libmssilk_init(f);
	libmsamr_init(f);
	libmsopenh264_init(f);
	libmswebrtc_init(f);
	libmscodec2_init(f);

	linphone_core_reload_ms_plugins(theLinphoneCore, NULL);
	[self migrationAllPost];
	
	linphone_core_enable_record_aware(theLinphoneCore, true); //force record aware enable

	/* Use the rootca from framework, which is already set*/
	//linphone_core_set_root_ca(theLinphoneCore, [LinphoneManager bundleFile:@"rootca.pem"].UTF8String);
	linphone_core_set_user_certificates_path(theLinphoneCore, linphone_factory_get_data_dir(linphone_factory_get(), kLinphoneMsgNotificationAppGroupId.UTF8String));

	/* The core will call the linphone_iphone_configuring_status_changed callback when the remote provisioning is loaded
	   (or skipped).
	   Wait for this to finish the code configuration */

	[NSNotificationCenter.defaultCenter addObserver:self
	 selector:@selector(globalStateChangedNotificationHandler:)
	 name:kLinphoneGlobalStateUpdate
	 object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inappReady:) name:kIAPReady object:nil];

	/*call iterate once immediately in order to initiate background connections with sip server or remote provisioning
	 * grab, if any */
	[self setDnsServer]; //configure DNS if custom DNS server is set
	[self iterate];
}

- (void)destroyLinphoneCore {
	// just in case
	[self removeCTCallCenterCb];
	[MagicSearchSingleton destroyInstance];

	if (theLinphoneCore != nil) { // just in case application terminate before linphone core initialization

		// rare case, remove duplicated fileTransferDelegates to avoid crash
		[_fileTransferDelegates setArray:[[NSSet setWithArray:_fileTransferDelegates] allObjects]];
		for (FileTransferDelegate *ftd in _fileTransferDelegates) {
			// Not remove here, avoid array mutated while being enumerated
			[ftd stopAndDestroyAndRemove:FALSE];
		}
		[_fileTransferDelegates removeAllObjects];
		
		if (linphone_core_get_global_state(LC) != LinphoneGlobalOff) {
			linphone_core_stop(LC);
		}
		linphone_core_unref(theLinphoneCore);
		LOGI(@"Destroy linphonecore %p", theLinphoneCore);
		theLinphoneCore = nil;

		// Post event
		NSDictionary *dict =
			[NSDictionary dictionaryWithObject:[NSValue valueWithPointer:theLinphoneCore] forKey:@"core"];
		[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneCoreUpdate
		 object:LinphoneManager.instance
		 userInfo:dict];
	}
	libStarted = FALSE;
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)resetLinphoneCore {
	[self destroyLinphoneCore];
	[self createLinphoneCore];
}

static int comp_call_id(const LinphoneCall *call, const char *callid) {
	if (linphone_call_log_get_call_id(linphone_call_get_call_log(call)) == nil) {
		ms_error("no callid for call [%p]", call);
		return 1;
	}
	return strcmp(linphone_call_log_get_call_id(linphone_call_get_call_log(call)), callid);
}

- (void)acceptCallForCallId:(NSString *)callid {
	// first, make sure this callid is not already involved in a call
	const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
	bctbx_list_t *call = bctbx_list_find_custom(calls, (bctbx_compare_func)comp_call_id, [callid UTF8String]);
	if (call != NULL) {
		const LinphoneVideoPolicy *video_policy = linphone_core_get_video_policy(theLinphoneCore);
		bool with_video = video_policy->automatically_accept;
		[CallManager.instance acceptCallWithCall:(LinphoneCall *)call->data hasVideo:with_video];
		return;
	};
}

- (void)addPushCallId:(NSString *)callid {
	// first, make sure this callid is not already involved in a call
	const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
	if (bctbx_list_find_custom(calls, (bctbx_compare_func)comp_call_id, [callid UTF8String])) {
		LOGW(@"Call id [%@] already handled", callid);
		return;
	};
	if ([pushCallIDs count] > 10 /*max number of pending notif*/)
		[pushCallIDs removeObjectAtIndex:0];

	[pushCallIDs addObject:callid];
}

- (BOOL)popPushCallID:(NSString *)callId {
	for (NSString *pendingNotif in pushCallIDs) {
		if ([pendingNotif compare:callId] == NSOrderedSame) {
			[pushCallIDs removeObject:pendingNotif];
			return TRUE;
		}
	}
	return FALSE;
}

- (BOOL)resignActive {
	linphone_core_stop_dtmf_stream(theLinphoneCore);

	return YES;
}

- (void)playMessageSound {
	BOOL success = [self.messagePlayer play];
	if (!success) {
		LOGE(@"Could not play the message sound");
	}
	AudioServicesPlaySystemSound(LinphoneManager.instance.sounds.vibrate);
}

static int comp_call_state_paused(const LinphoneCall *call, const void *param) {
	return linphone_call_get_state(call) != LinphoneCallPaused;
}

- (void)startCallPausedLongRunningTask {
	pausedCallBgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
			LOGW(@"Call cannot be paused any more, too late");
			[[UIApplication sharedApplication] endBackgroundTask:pausedCallBgTask];
		}];
	LOGI(@"Long running task started, remaining [%@] because at least one call is paused",
	     [LinphoneUtils intervalToString:[[UIApplication sharedApplication] backgroundTimeRemaining]]);
}

- (void)enableProxyPublish:(BOOL)enabled {
	if (linphone_core_get_global_state(LC) != LinphoneGlobalOn || !linphone_core_get_default_friend_list(LC)) {
		LOGW(@"Not changing presence configuration because linphone core not ready yet");
		return;
	}

	if ([self lpConfigBoolForKey:@"publish_presence"]) {
		// set present to "tv", because "available" does not work yet
		if (enabled) {
			linphone_core_set_presence_model(LC, linphone_core_create_presence_model_with_activity(LC, LinphonePresenceActivityTV, NULL));
		}

		const MSList *accounts = linphone_core_get_account_list(LC);
		while (accounts) {
			LinphoneAccount *account = accounts->data;
			LinphoneAccountParams *newAccountParams = linphone_account_params_clone(linphone_account_get_params(account));
			linphone_account_params_set_publish_enabled(newAccountParams, enabled);
			linphone_account_set_params(account, newAccountParams);
			linphone_account_params_unref(newAccountParams);
			accounts = accounts->next;
		}
		// force registration update first, then update friend list subscription
		[self iterate];
	}

	linphone_core_enable_friend_list_subscription(LC, enabled && [LinphoneManager.instance lpConfigBoolForKey:@"use_rls_presence"]);
}

- (BOOL)enterBackgroundMode {
	LinphoneAccount *account = linphone_core_get_default_account(theLinphoneCore);
	BOOL shouldEnterBgMode = FALSE;

	// disable presence
	[self enableProxyPublish:NO];

	// handle proxy config if any
	if (account) {
		LinphoneAccountParams const *accountParams = linphone_account_get_params(account);
		BOOL pushNotifEnabled = linphone_account_params_get_push_notification_allowed(accountParams);
		if ([LinphoneManager.instance lpConfigBoolForKey:@"backgroundmode_preference"] || pushNotifEnabled) {
			if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
				// For registration register
				[self refreshRegisters];
			}
		}

		if ([LinphoneManager.instance lpConfigBoolForKey:@"voip_mode_preference"] && [LinphoneManager.instance lpConfigBoolForKey:@"backgroundmode_preference"] && !pushNotifEnabled) {
            // Keep this!! Socket VoIP is deprecated after 9.0, but sometimes it's the only way to keep the phone background and receive the call. For example, when there is only local area network.
            // register keepalive
            if ([[UIApplication sharedApplication]
                 setKeepAliveTimeout:600 /*(NSTimeInterval)linphone_proxy_config_get_expires(proxyCfg)*/
                 handler:^{
                     LOGW(@"keepalive handler");
                     mLastKeepAliveDate = [NSDate date];
                     if (theLinphoneCore == nil) {
                         LOGW(@"It seems that Linphone BG mode was deactivated, just skipping");
                         return;
                     }
                     [_iapManager check];
                     if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
                         // For registration register
                         [self refreshRegisters];
                     }
                     linphone_core_iterate(theLinphoneCore);
                 }]) {
		     LOGI(@"keepalive handler succesfully registered");
                 } else {
                     LOGI(@"keepalive handler cannot be registered");
                 }
			shouldEnterBgMode = TRUE;
		}
	}

	LinphoneCall *currentCall = linphone_core_get_current_call(theLinphoneCore);
	const bctbx_list_t *callList = linphone_core_get_calls(theLinphoneCore);
	if (!currentCall // no active call
	    && callList  // at least one call in a non active state
	    && bctbx_list_find_custom(callList, (bctbx_compare_func)comp_call_state_paused, NULL)) {
		[self startCallPausedLongRunningTask];
	}
	if (callList) // If at least one call exist, enter normal bg mode
		shouldEnterBgMode = TRUE;

	// Stop the video preview
	if (theLinphoneCore) {
		linphone_core_enable_video_preview(theLinphoneCore, FALSE);
		[self iterate];
	}

	LOGI(@"Entering [%s] bg mode", shouldEnterBgMode ? "normal" : "lite");
	if (!shouldEnterBgMode && floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
		if (account) {
			LinphoneAccountParams const *accountParams = linphone_account_get_params(account);
			BOOL pushNotifEnabled = linphone_account_params_get_push_notification_allowed(accountParams);
			if (pushNotifEnabled) {
				LOGI(@"Keeping lc core to handle push");
				return YES;
			}
			return NO;
		}
	}
	return YES;
}

- (void)becomeActive {
	[self checkNewVersion];

	// enable presence
	if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
		[self refreshRegisters];
	}
	if (pausedCallBgTask) {
		[[UIApplication sharedApplication] endBackgroundTask:pausedCallBgTask];
		pausedCallBgTask = 0;
	}
	if (incallBgTask) {
		[[UIApplication sharedApplication] endBackgroundTask:incallBgTask];
		incallBgTask = 0;
	}

	/*IOS specific*/
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
	 completionHandler:^(BOOL granted){
		}];
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
	 completionHandler:^(BOOL granted){
		}];

	/*start the video preview in case we are in the main view*/
	if (linphone_core_video_display_enabled(theLinphoneCore) && [self lpConfigBoolForKey:@"preview_preference"]) {
		linphone_core_enable_video_preview(theLinphoneCore, TRUE);
	}
	/*check last keepalive handler date*/
	if (mLastKeepAliveDate != Nil) {
		NSDate *current = [NSDate date];
		if ([current timeIntervalSinceDate:mLastKeepAliveDate] > 700) {
			NSString *datestr = [mLastKeepAliveDate description];
			LOGW(@"keepalive handler was called for the last time at %@", datestr);
		}
	}

	[self enableProxyPublish:YES];
}

- (void)refreshRegisters {
	linphone_core_refresh_registers(theLinphoneCore); // just to make sure REGISTRATION is up to date
}

- (void)migrationAllImages {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSArray *images = [fileManager contentsOfDirectoryAtPath:[LinphoneManager cacheDirectory] error:NULL];

	for (NSString *image in images)
	{
		[fileManager copyItemAtPath:[[LinphoneManager cacheDirectory] stringByAppendingPathComponent:image] toPath:[[LinphoneManager imagesDirectory] stringByAppendingPathComponent:image] error:nil];
	}
	[self lpConfigSetBool:TRUE forKey:@"migration_images_done"];
}

- (void)migrateImportantFiles {
	if ([LinphoneManager copyFile:[LinphoneManager oldPreferenceFile:@"linphonerc"] destination:[LinphoneManager preferenceFile:@"linphonerc"] override:TRUE ignore:TRUE]) {
		[NSFileManager.defaultManager
		removeItemAtPath:[LinphoneManager oldPreferenceFile:@"linphonerc"]
		error:nil];
	} else if ([LinphoneManager copyFile:[LinphoneManager documentFile:@"linphonerc"] destination:[LinphoneManager preferenceFile:@"linphonerc"] override:TRUE ignore:TRUE]) {
		[NSFileManager.defaultManager
		removeItemAtPath:[LinphoneManager documentFile:@"linphonerc"]
		error:nil];
	}

	if ([LinphoneManager copyFile:[LinphoneManager oldDataFile:@"linphone.db"] destination:[LinphoneManager dataFile:@"linphone.db"] override:TRUE ignore:TRUE]) {
		[NSFileManager.defaultManager
		removeItemAtPath:[LinphoneManager oldDataFile:@"linphone.db"]
		error:nil];
	}

	if ([LinphoneManager copyFile:[LinphoneManager oldDataFile:@"x3dh.c25519.sqlite3"] destination:[LinphoneManager dataFile:@"x3dh.c25519.sqlite3"] override:TRUE ignore:TRUE]) {
		[NSFileManager.defaultManager
		removeItemAtPath:[LinphoneManager oldDataFile:@"x3dh.c25519.sqlite3"]
		error:nil];
	}

	// call history
	if ([LinphoneManager copyFile:[LinphoneManager oldDataFile:kLinphoneInternalChatDBFilename] destination:[LinphoneManager dataFile:kLinphoneInternalChatDBFilename] override:TRUE ignore:TRUE]) {
		[NSFileManager.defaultManager
		removeItemAtPath:[LinphoneManager oldDataFile:kLinphoneInternalChatDBFilename]
		error:nil];
	}

	if ([LinphoneManager copyFile:[LinphoneManager oldDataFile:@"zrtp_secrets"] destination:[LinphoneManager dataFile:@"zrtp_secrets"] override:TRUE ignore:TRUE]) {
		[NSFileManager.defaultManager
		removeItemAtPath:[LinphoneManager oldDataFile:@"zrtp_secrets"]
		error:nil];
	}
}

- (void)renameDefaultSettings {
	// rename .linphonerc to linphonerc to ease debugging: when downloading
	// containers from MacOSX, Finder do not display hidden files leading
	// to useless painful operations to display the .linphonerc file
	NSString *src = [LinphoneManager documentFile:@".linphonerc"];
	NSString *dst = [LinphoneManager preferenceFile:@"linphonerc"];
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSError *fileError = nil;
	if ([fileManager fileExistsAtPath:src]) {
		if ([fileManager fileExistsAtPath:dst]) {
			[fileManager removeItemAtPath:src error:&fileError];
			LOGW(@"%@ already exists, simply removing %@ %@", dst, src,
			     fileError ? fileError.localizedDescription : @"successfully");
		} else {
			[fileManager moveItemAtPath:src toPath:dst error:&fileError];
			LOGW(@"%@ moving to %@ %@", dst, src, fileError ? fileError.localizedDescription : @"successfully");
		}
	}
}

- (void)copyDefaultSettings {
	NSString *src = [LinphoneManager bundleFile:@"linphonerc"];
	NSString *srcIpad = [LinphoneManager bundleFile:@"linphonerc~ipad"];
	if (IPAD && [[NSFileManager defaultManager] fileExistsAtPath:srcIpad]) {
		src = srcIpad;
	}
	NSString *dst = [LinphoneManager preferenceFile:@"linphonerc"];
	[LinphoneManager copyFile:src destination:dst override:FALSE ignore:FALSE];
}

- (void)overrideDefaultSettings {
	NSString *factory = [LinphoneManager bundleFile:@"linphonerc-factory"];
	NSString *factoryIpad = [LinphoneManager bundleFile:@"linphonerc-factory~ipad"];
	if (IPAD && [[NSFileManager defaultManager] fileExistsAtPath:factoryIpad]) {
		factory = factoryIpad;
	}
	_configDb = linphone_config_new_for_shared_core(kLinphoneMsgNotificationAppGroupId.UTF8String, @"linphonerc".UTF8String, factory.UTF8String);
	if (linphone_config_has_entry(_configDb, "misc", "max_calls")) { // Not doable on core on iOS (requires CallKit) -> flag moved to app section, and have app handle it in ProviderDelegate
		linphone_config_set_int(_configDb, "app", "max_calls", linphone_config_get_int(_configDb,"misc", "max_calls",10));
		linphone_config_clean_entry(_configDb, "misc", "max_calls");
	}
}
#pragma mark - Audio route Functions

#pragma mark - Call Functions
- (void)send:(NSString *)replyText toChatRoom:(LinphoneChatRoom *)room {	
	LinphoneChatMessage *msg = linphone_chat_room_create_message(room, replyText.UTF8String);
	linphone_chat_message_send(msg);

	[ChatConversationViewSwift markAsRead:room];
}

/*
 * If ICE is enabled, check if local network permission is given and show an alert message.
 * It is indeed required for ICE to operate correctly.
 * If it is not the the case, liblinphone will automatically skip ICE during the call.
 * The purpose of this function is only to show the alert message.
 */
- (void) checkLocalNetworkPermission{
	NSString *alertSuppressionKey = @"LocalNetworkPermissionAlertSuppression";
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	LinphoneProxyConfig *defaultCfg = linphone_core_get_default_proxy_config(LC);
	if (!defaultCfg) return;
	LinphoneNatPolicy *natPolicy = linphone_proxy_config_get_nat_policy(defaultCfg);
	if (!natPolicy || !linphone_nat_policy_ice_enabled(natPolicy))
		return;
	
	if (linphone_core_local_permission_enabled(LC)) return;
	

	if (![defaults boolForKey: alertSuppressionKey]) {
		UIAlertController *noticeView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Local network usage", nil)
						  message:NSLocalizedString(@"Granting the local network permission is recommended to enhance the audio & video quality. You may enable it from iOS settings.", nil)
						  preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
						style:UIAlertActionStyleDefault
						handler:^(UIAlertAction * action) {}];
		UIAlertAction* ignoreForeverAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Don't show this again.", nil)
						style:UIAlertActionStyleCancel
						handler:^(UIAlertAction * action) {
			[defaults setBool:TRUE forKey: alertSuppressionKey];
		}];

		[noticeView addAction:defaultAction];
		[noticeView addAction:ignoreForeverAction];
		[PhoneMainView.instance presentViewController:noticeView animated:YES completion:nil];
	}
}

- (void)call:(const LinphoneAddress *)iaddr {
	// First verify that network is available, abort otherwise.
	if (!linphone_core_is_network_reachable(theLinphoneCore)) {
		[PhoneMainView.instance presentViewController:[LinphoneUtils networkErrorView:@"place a call"] animated:YES completion:nil];
		return;
	}

	// Then check that no GSM calls are in progress, abort otherwise.
	CTCallCenter *callCenter = [[CTCallCenter alloc] init];
	if ([callCenter currentCalls] != nil && floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
		LOGE(@"GSM call in progress, cancelling outgoing SIP call request");
		UIAlertController *errView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Cannot make call", nil)
					      message:NSLocalizedString(@"Please terminate GSM call first.", nil)
					      preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
						style:UIAlertActionStyleDefault
						handler:^(UIAlertAction * action) {}];

		[errView addAction:defaultAction];
		[PhoneMainView.instance presentViewController:errView animated:YES completion:nil];
		return;
	}

	// Then check that the supplied address is valid
	if (!iaddr) {
		UIAlertController *errView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Invalid SIP address", nil)
					      message:NSLocalizedString(@"Either configure a SIP proxy server from settings prior to place a "
									@"call or use a valid SIP address (I.E sip:john@example.net)", nil)
					      preferredStyle:UIAlertControllerStyleAlert];

		UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
						style:UIAlertActionStyleDefault
						handler:^(UIAlertAction * action) {}];

		[errView addAction:defaultAction];
		[PhoneMainView.instance presentViewController:errView animated:YES completion:nil];
		return;
	}
	[self checkLocalNetworkPermission];
	// For OutgoingCall, show CallOutgoingView
	LinphoneVideoActivationPolicy *policy = linphone_core_get_video_activation_policy(LC);
	BOOL initiateVideoCall =  linphone_video_activation_policy_get_automatically_initiate(policy);
	[CallManager.instance startCallWithAddr:iaddr isSas:FALSE isVideo:initiateVideoCall isConference:false];
	linphone_video_activation_policy_unref(policy);
}

#pragma mark - Misc Functions
+ (PHFetchResult *)getPHAssets:(NSString *)key {
	PHFetchResult<PHAsset *> *assets;
	if ([key hasPrefix:@"assets-library"]) {
		// compability with previous linphone version
		assets = [PHAsset fetchAssetsWithALAssetURLs:@[[NSURL URLWithString:key]] options:nil];
	} else {
		assets = [PHAsset fetchAssetsWithLocalIdentifiers:[NSArray arrayWithObject:key] options:nil];
	}
	return assets;
}

+ (NSString *)bundleFile:(NSString *)file {
	return [[NSBundle mainBundle] pathForResource:[file stringByDeletingPathExtension] ofType:[file pathExtension]];
}

+ (NSString *)documentFile:(NSString *)file {
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = [paths objectAtIndex:0];
	return [documentsPath stringByAppendingPathComponent:file];
}

+ (NSString *)preferenceFile:(NSString *)file {
	LinphoneFactory *factory = linphone_factory_get();
	NSString *fullPath = [NSString stringWithUTF8String:linphone_factory_get_config_dir(factory, kLinphoneMsgNotificationAppGroupId.UTF8String)];
	return [fullPath stringByAppendingPathComponent:file];
}

+ (NSString *)dataFile:(NSString *)file {
	LinphoneFactory *factory = linphone_factory_get();
	NSString *fullPath = [NSString stringWithUTF8String:linphone_factory_get_data_dir(factory, kLinphoneMsgNotificationAppGroupId.UTF8String)];
	return [fullPath stringByAppendingPathComponent:file];
}

+ (NSString *)imagesDirectory {
	NSURL *basePath = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kLinphoneMsgNotificationAppGroupId];
	NSString *fullPath = [[basePath path] stringByAppendingString:@"/Library/Images/"];
	if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
		NSError *error;
		LOGW(@"Download path %@ does not exist, creating it.", fullPath);
		if (![[NSFileManager defaultManager] createDirectoryAtPath:fullPath
									   withIntermediateDirectories:YES
														attributes:nil
															 error:&error]) {
			LOGE(@"Create download path directory error: %@", error.description);
		}
	}
	return fullPath;
}

+ (NSString *)cacheDirectory {
	NSURL *basePath = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kLinphoneMsgNotificationAppGroupId];
	NSString *fullPath = [[basePath path] stringByAppendingString:@"/Library/Caches/"];
	if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
		NSError *error;
		LOGW(@"Download path %@ does not exist, creating it.", fullPath);
		if (![[NSFileManager defaultManager] createDirectoryAtPath:fullPath
									   withIntermediateDirectories:YES
														attributes:nil
															 error:&error]) {
			LOGE(@"Create download path directory error: %@", error.description);
		}
	}
	return fullPath;
}

+ (NSString *)validFilePath:(NSString *)name {
	NSString *filePath = [[LinphoneManager imagesDirectory] stringByAppendingPathComponent:name];
	if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
		return filePath;
	}
	// if migration (move files of cacheDirectory to imagesDirectory) failed
	return [[LinphoneManager cacheDirectory] stringByAppendingPathComponent:name];
}

+ (NSString *)oldPreferenceFile:(NSString *)file {
	// migration
	LinphoneFactory *factory = linphone_factory_get();
	NSString *fullPath = [NSString stringWithUTF8String:linphone_factory_get_config_dir(factory, nil)];
	return [fullPath stringByAppendingPathComponent:file];
}

+ (NSString *)oldDataFile:(NSString *)file {
	// migration
	LinphoneFactory *factory = linphone_factory_get();
	NSString *fullPath = [NSString stringWithUTF8String:linphone_factory_get_data_dir(factory, nil)];
	return [fullPath stringByAppendingPathComponent:file];
}

+ (int)unreadMessageCount {
	int count = 0;
	const MSList *rooms = linphone_core_get_chat_rooms(LC);
	const MSList *item = rooms;
	while (item) {
		LinphoneChatRoom *room = (LinphoneChatRoom *)item->data;
		if (room) {
			count += linphone_chat_room_get_unread_messages_count(room);
		}
		item = item->next;
	}

	return count;
}

+ (BOOL)copyFile:(NSString *)src destination:(NSString *)dst override:(BOOL)override ignore:(BOOL)ignore {
	NSFileManager *fileManager = NSFileManager.defaultManager;
	NSError *error = nil;
	if ([fileManager fileExistsAtPath:src] == NO) {
		if (!ignore)
			LOGE(@"Can't find \"%@\": %@", src, [error localizedDescription]);
		return FALSE;
	}
	if ([fileManager fileExistsAtPath:dst] == YES) {
		if (override) {
			[fileManager removeItemAtPath:dst error:&error];
			if (error != nil) {
				LOGE(@"Can't remove \"%@\": %@", dst, [error localizedDescription]);
				return FALSE;
			}
		} else {
			LOGW(@"\"%@\" already exists", dst);
			return FALSE;
		}
	}
	[fileManager copyItemAtPath:src toPath:dst error:&error];
	if (error != nil) {
		LOGE(@"Can't copy \"%@\" to \"%@\": %@", src, dst, [error localizedDescription]);
		return FALSE;
	}
	return TRUE;
}

- (void)configureVbrCodecs {
	PayloadType *pt;
	int bitrate = linphone_config_get_int(
					_configDb, "audio", "codec_bitrate_limit",
					kLinphoneAudioVbrCodecDefaultBitrate); /*default value is in linphonerc or linphonerc-factory*/
	const MSList *audio_codecs = linphone_core_get_audio_codecs(theLinphoneCore);
	const MSList *codec = audio_codecs;
	while (codec) {
		pt = codec->data;
		if (linphone_core_payload_type_is_vbr(theLinphoneCore, pt)) {
			linphone_core_set_payload_type_bitrate(theLinphoneCore, pt, bitrate);
		}
		codec = codec->next;
	}
}

+ (id)getMessageAppDataForKey:(NSString *)key inMessage:(LinphoneChatMessage *)msg {

	if (msg == nil)
		return nil;

	id value = nil;
	const char *appData = linphone_chat_message_get_appdata(msg);
	if (appData) {
		NSDictionary *appDataDict =
			[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:appData length:strlen(appData)]
			 options:0
			 error:nil];
		value = [appDataDict objectForKey:key];
	}
	return value;
}

+ (void)setValueInMessageAppData:(id)value forKey:(NSString *)key inMessage:(LinphoneChatMessage *)msg {
        NSMutableDictionary *appDataDict = [NSMutableDictionary dictionary];
        const char *appData = linphone_chat_message_get_appdata(msg);
        if (appData) {
		appDataDict = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:appData length:strlen(appData)]
			       options:NSJSONReadingMutableContainers
			       error:nil];
        }

        [appDataDict setValue:value forKey:key];

        NSData *data = [NSJSONSerialization dataWithJSONObject:appDataDict options:0 error:nil];
        NSString *appdataJSON = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        linphone_chat_message_set_appdata(msg, [appdataJSON UTF8String]);
}

#pragma mark - LPConfig Functions

- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key {
	[self lpConfigSetString:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}
- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key inSection:(NSString *)section {
	if (!key)
		return;
	linphone_config_set_string(_configDb, [section UTF8String], [key UTF8String], value ? [value UTF8String] : NULL);
}
- (NSString *)lpConfigStringForKey:(NSString *)key {
	return [self lpConfigStringForKey:key withDefault:nil];
}
- (NSString *)lpConfigStringForKey:(NSString *)key withDefault:(NSString *)defaultValue {
	return [self lpConfigStringForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section {
	return [self lpConfigStringForKey:key inSection:section withDefault:nil];
}
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section withDefault:(NSString *)defaultValue {
	if (!key)
		return defaultValue;
	const char *value = linphone_config_get_string(_configDb, [section UTF8String], [key UTF8String], NULL);
	return value ? [NSString stringWithUTF8String:value] : defaultValue;
}

- (void)lpConfigSetInt:(int)value forKey:(NSString *)key {
	[self lpConfigSetInt:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}
- (void)lpConfigSetInt:(int)value forKey:(NSString *)key inSection:(NSString *)section {
	if (!key)
		return;
	linphone_config_set_int(_configDb, [section UTF8String], [key UTF8String], (int)value);
}
- (int)lpConfigIntForKey:(NSString *)key {
	return [self lpConfigIntForKey:key withDefault:-1];
}
- (int)lpConfigIntForKey:(NSString *)key withDefault:(int)defaultValue {
	return [self lpConfigIntForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section {
	return [self lpConfigIntForKey:key inSection:section withDefault:-1];
}
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section withDefault:(int)defaultValue {
	if (!key)
		return defaultValue;
	return linphone_config_get_int(_configDb, [section UTF8String], [key UTF8String], (int)defaultValue);
}

- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key {
	[self lpConfigSetBool:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}
- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key inSection:(NSString *)section {
	[self lpConfigSetInt:(int)(value == TRUE) forKey:key inSection:section];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key {
	return [self lpConfigBoolForKey:key withDefault:FALSE];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key withDefault:(BOOL)defaultValue {
	return [self lpConfigBoolForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section {
	return [self lpConfigBoolForKey:key inSection:section withDefault:FALSE];
}
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section withDefault:(BOOL)defaultValue {
	if (!key)
		return defaultValue;
	int val = [self lpConfigIntForKey:key inSection:section withDefault:-1];
	return (val != -1) ? (val == 1) : defaultValue;
}

#pragma mark - GSM management

- (void)removeCTCallCenterCb {
	if (mCallCenter != nil) {
		LOGI(@"Removing CT call center listener [%p]", mCallCenter);
		mCallCenter.callEventHandler = NULL;
	}
	mCallCenter = nil;
}

- (BOOL)isCTCallCenterExist {
	return mCallCenter != nil;
}

- (void)setupGSMInteraction {

	[self removeCTCallCenterCb];
	mCallCenter = [[CTCallCenter alloc] init];
	LOGI(@"Adding CT call center listener [%p]", mCallCenter);
	__block __weak LinphoneManager *weakSelf = self;
	__block __weak CTCallCenter *weakCCenter = mCallCenter;
	mCallCenter.callEventHandler = ^(CTCall *call) {
		// post on main thread
		[weakSelf performSelectorOnMainThread:@selector(handleGSMCallInteration:)
		 withObject:weakCCenter
		 waitUntilDone:YES];
	};
}

- (void)handleGSMCallInteration:(id)cCenter {
	if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_9_x_Max) {
		CTCallCenter *ct = (CTCallCenter *)cCenter;
		// pause current call, if any
		LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
		if ([ct currentCalls] != nil) {
			if (call) {
				LOGI(@"Pausing SIP call because GSM call");
				CallManager.instance.speakerBeforePause = [CallManager.instance isSpeakerEnabled];
				linphone_call_pause(call);
				[self startCallPausedLongRunningTask];
			} else if (linphone_core_is_in_conference(theLinphoneCore)) {
				LOGI(@"Leaving conference call because GSM call");
				linphone_core_leave_conference(theLinphoneCore);
				[self startCallPausedLongRunningTask];
			}
		} // else nop, keep call in paused state
	}
}

- (NSString *)contactFilter {
	NSString *filter = @"*";
	if ([self lpConfigBoolForKey:@"contact_filter_on_default_domain"]) {
		LinphoneAccount *account = linphone_core_get_default_account(theLinphoneCore);
		if (!account)
			return filter;
		LinphoneAccountParams const *accountParams = linphone_account_get_params(account);
		if (account && linphone_account_params_get_server_addr(accountParams)) {
			return [NSString stringWithCString:linphone_account_params_get_domain(accountParams)
				encoding:[NSString defaultCStringEncoding]];
		}
	}
	return filter;
}

#pragma mark - InApp Purchase events

- (void)inappReady:(NSNotification *)notif {
	// Query our in-app server to retrieve InApp purchases
	//[_iapManager retrievePurchases];
}

#pragma mark -

- (MSList *) createAccountsNotHiddenList {
	MSList *list = NULL;
	const MSList *accounts = linphone_core_get_account_list(LC);
	while (accounts) {
		const char *isHidden = linphone_account_get_custom_param(accounts->data, "hidden");
		if (isHidden == NULL || strcmp(linphone_account_get_custom_param(accounts->data, "hidden"), "1") != 0) {
			if (!list) {
				list = bctbx_list_new(accounts->data);
			} else {
				bctbx_list_append(list, accounts->data);
			}
		}
		accounts = accounts->next;
	}
	return list;
}

- (void)removeAllAccounts {
	linphone_core_clear_accounts(LC);
	linphone_core_clear_all_auth_info(LC);
}

+ (BOOL)isMyself:(const LinphoneAddress *)addr {
	if (!addr)
		return NO;

	const MSList *accounts = linphone_core_get_account_list(LC);
	while (accounts) {
		if (linphone_address_weak_equal(addr, linphone_account_params_get_identity_address(linphone_account_get_params(accounts->data)))) {
			return YES;
		}
		accounts = accounts->next;
	}
	return NO;
}

// ugly hack to export symbol from liblinphone so that they are available for the linphoneTests target
// linphoneTests target do not link with liblinphone but instead dynamically link with ourself which is
// statically linked with liblinphone, so we must have exported required symbols from the library to
// have them available in linphoneTests
// DO NOT INVOKE THIS METHOD
- (void)exportSymbolsForUITests {
	linphone_address_set_header(NULL, NULL, NULL);
}

- (void)checkNewVersion {
	if (!CHECK_VERSION_UPDATE)
		return;
	if (theLinphoneCore == nil)
		return;
	NSString *curVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	const char *curVersionCString = [curVersion cStringUsingEncoding:NSUTF8StringEncoding];
	linphone_core_check_for_update(theLinphoneCore, curVersionCString);
}

- (void)loadAvatar {
	NSString *assetId = [self lpConfigStringForKey:@"avatar"];
	__block UIImage *ret = nil;
	if (assetId) {
		PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:[NSArray arrayWithObject:assetId] options:nil];
		if (![assets firstObject]) {
			LOGE(@"Can't fetch avatar image.");
		}
		PHAsset *asset = [assets firstObject];
		// load avatar synchronously so that we can return UIIMage* directly - since we are
		// only using thumbnail, it must be pretty fast to fetch even without cache.
		PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
		options.synchronous = TRUE;
		[[PHImageManager defaultManager] requestImageForAsset:asset targetSize:PHImageManagerMaximumSize contentMode:PHImageContentModeDefault options:options
		 resultHandler:^(UIImage *image, NSDictionary * info) {
				if (image)
					ret = [UIImage UIImageThumbnail:image thumbSize:150];
				else
					LOGE(@"Can't read avatar");
			}];
	}
    
	if (!ret) {
		ret = [UIImage imageNamed:@"avatar.png"];
	}
	_avatar = ret;
}

#pragma mark - Conference



void conference_participant_changed(LinphoneConference *conference, const LinphoneParticipant *participant) {
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneConfStateParticipantListChanged object:nil];
}

void conference_device_changed(LinphoneConference *conference, const LinphoneParticipantDevice *participant) {
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneConfStateParticipantListChanged object:nil];
}

void linphone_iphone_conference_state_changed(LinphoneCore *lc, LinphoneConference *conf,LinphoneConferenceState state) {
	
	if (state == LinphoneConferenceStateCreated) {
		LinphoneConferenceCbs * cbs = linphone_factory_create_conference_cbs(linphone_factory_get());
		linphone_conference_cbs_set_participant_added(cbs, conference_participant_changed);
		linphone_conference_cbs_set_participant_device_added(cbs, conference_device_changed);
		linphone_conference_cbs_set_participant_device_removed(cbs, conference_device_changed);
		linphone_conference_cbs_set_participant_removed(cbs, conference_participant_changed);
		linphone_conference_add_callbacks(conf, cbs);
	}
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	[dict setObject:[NSNumber numberWithInt:state] forKey:@"state"];
	[NSNotificationCenter.defaultCenter postNotificationName:kLinphoneConfStateChanged object:nil userInfo:dict];
}

+ (BOOL) getChatroomPushEnabled:(LinphoneChatRoom *)chatroom {
	bool currently_enabled = true;
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kLinphoneMsgNotificationAppGroupId];
	NSDictionary *chatroomsPushStatus = [defaults dictionaryForKey:@"chatroomsPushStatus"];
	if (chatroomsPushStatus != nil && chatroom) {
		char *uri = linphone_address_as_string_uri_only(linphone_chat_room_get_peer_address(chatroom));
		NSString* pushStatus = [chatroomsPushStatus objectForKey:[NSString stringWithUTF8String:uri]];
		currently_enabled = (pushStatus == nil) || [pushStatus isEqualToString:@"enabled"];
		ms_free(uri);
	}
	return currently_enabled;
}

+ (void) setChatroomPushEnabled:(LinphoneChatRoom *)chatroom withPushEnabled:(BOOL)enabled {
	if (!chatroom) return;
	
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kLinphoneMsgNotificationAppGroupId];
	NSMutableDictionary *chatroomsPushStatus = [[NSMutableDictionary alloc] initWithDictionary:[defaults dictionaryForKey:@"chatroomsPushStatus"]];
	if (chatroomsPushStatus == nil) chatroomsPushStatus = [[NSMutableDictionary dictionary] init];
	
	char *uri = linphone_address_as_string_uri_only(linphone_chat_room_get_peer_address(chatroom));
	[chatroomsPushStatus setValue:(enabled ? @"enabled" : @"disabled") forKey:[NSString stringWithUTF8String:uri]];
	ms_free(uri);
	
	[defaults setObject:chatroomsPushStatus forKey:@"chatroomsPushStatus"];
}

@end
