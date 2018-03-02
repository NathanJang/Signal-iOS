//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "Pastelog.h"
#import "Signal-Swift.h"
#import "ThreadUtil.h"
#import <AFNetworking/AFNetworking.h>
#import <SSZipArchive/SSZipArchive.h>
#import <SignalMessaging/DebugLogger.h>
#import <SignalMessaging/Environment.h>
#import <SignalServiceKit/AppContext.h>
#import <SignalServiceKit/TSAccountManager.h>
#import <SignalServiceKit/TSContactThread.h>
#import <SignalServiceKit/TSStorageManager.h>
#import <SignalServiceKit/Threading.h>

// TODO: Remove
#import "NSData+hexString.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^UploadDebugLogsSuccess)(NSURL *url);
typedef void (^UploadDebugLogsFailure)(NSString *localizedErrorMessage);

#pragma mark -

@class DebugLogUploader;

typedef void (^DebugLogUploadSuccess)(DebugLogUploader *uploader, NSURL *url);
typedef void (^DebugLogUploadFailure)(DebugLogUploader *uploader, NSError *error);

@interface DebugLogUploader : NSObject

@property (nonatomic) NSURL *fileUrl;
@property (nonatomic) NSString *mimeType;
@property (nonatomic, nullable) DebugLogUploadSuccess success;
@property (nonatomic, nullable) DebugLogUploadFailure failure;

@end

#pragma mark -

@implementation DebugLogUploader

- (void)dealloc
{
    DDLogVerbose(@"Dealloc: %@", self.logTag);
}

- (void)uploadFileWithURL:(NSURL *)fileUrl
                 mimeType:(NSString *)mimeType
                  success:(DebugLogUploadSuccess)success
                  failure:(DebugLogUploadFailure)failure
{
    OWSAssert(fileUrl);
    OWSAssert(mimeType.length > 0);
    OWSAssert(success);
    OWSAssert(failure);

    self.fileUrl = fileUrl;
    self.mimeType = mimeType;
    self.success = success;
    self.failure = failure;

    // TODO: Remove
    NSData *data = [NSData dataWithContentsOfURL:fileUrl];
    DDLogInfo(@"%@ data: %zd", self.logTag, data.length);
    NSData *header = [data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)256, data.length))];
    NSString *hexString = [header hexadecimalString];
    DDLogInfo(@"%@ hexString: %@", self.logTag, hexString);

    [self getUploadParameters];
}

- (void)getUploadParameters
{
    __weak DebugLogUploader *weakSelf = self;

    // TODO: Remove
    // The JSON object it returns has two elements, URL, and "fields". Just POST to "ur" with a multipart/form-data body
    // that has each KV pair in "fields" encoded as a form element. Add your file, called "file", and what you post will
    // be at debuglogs.org/fields['key']

    NSURLSessionConfiguration *sessionConf = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    AFHTTPSessionManager *sessionManager =
        [[AFHTTPSessionManager alloc] initWithBaseURL:nil sessionConfiguration:sessionConf];
    sessionManager.requestSerializer = [AFHTTPRequestSerializer serializer];
    sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
    NSString *urlString = @"https://debuglogs.org/";
    [sessionManager GET:urlString
        parameters:nil
        progress:nil
        success:^(NSURLSessionDataTask *task, id _Nullable responseObject) {
            if (![responseObject isKindOfClass:[NSDictionary class]]) {
                DDLogError(@"%@ Invalid response: %@, %@", weakSelf.logTag, urlString, responseObject);
                [weakSelf
                    failWithError:OWSErrorWithCodeDescription(OWSErrorCodeDebugLogUploadFailed, @"Invalid response")];
                return;
            }
            NSString *uploadUrl = responseObject[@"url"];
            if (![uploadUrl isKindOfClass:[NSString class]] || uploadUrl.length < 1) {
                DDLogError(@"%@ Invalid response: %@, %@", weakSelf.logTag, urlString, responseObject);
                [weakSelf
                    failWithError:OWSErrorWithCodeDescription(OWSErrorCodeDebugLogUploadFailed, @"Invalid response")];
                return;
            }
            NSDictionary *fields = responseObject[@"fields"];
            if (![fields isKindOfClass:[NSDictionary class]] || fields.count < 1) {
                DDLogError(@"%@ Invalid response: %@, %@", weakSelf.logTag, urlString, responseObject);
                [weakSelf
                    failWithError:OWSErrorWithCodeDescription(OWSErrorCodeDebugLogUploadFailed, @"Invalid response")];
                return;
            }
            for (NSString *fieldName in fields) {
                NSString *fieldValue = fields[fieldName];
                if (![fieldName isKindOfClass:[NSString class]] || fieldName.length < 1
                    || ![fieldValue isKindOfClass:[NSString class]] || fieldValue.length < 1) {
                    DDLogError(@"%@ Invalid response: %@, %@", weakSelf.logTag, urlString, responseObject);
                    [weakSelf failWithError:OWSErrorWithCodeDescription(
                                                OWSErrorCodeDebugLogUploadFailed, @"Invalid response")];
                    return;
                }
            }
            NSString *_Nullable uploadKey = fields[@"key"];
            if (![uploadKey isKindOfClass:[NSString class]] || uploadKey.length < 1) {
                DDLogError(@"%@ Invalid response: %@, %@", weakSelf.logTag, urlString, responseObject);
                [weakSelf
                    failWithError:OWSErrorWithCodeDescription(OWSErrorCodeDebugLogUploadFailed, @"Invalid response")];
                return;
            }
            [weakSelf uploadFileWithUploadUrl:uploadUrl fields:fields uploadKey:uploadKey];
        }
        failure:^(NSURLSessionDataTask *_Nullable task, NSError *error) {
            DDLogError(@"%@ failed: %@", weakSelf.logTag, urlString);
            [weakSelf failWithError:error];
        }];
}

- (void)uploadFileWithUploadUrl:(NSString *)uploadUrl fields:(NSDictionary *)fields uploadKey:(NSString *)uploadKey
{
    OWSAssert(uploadUrl.length > 0);
    OWSAssert(fields);
    OWSAssert(uploadKey.length > 0);

    __weak DebugLogUploader *weakSelf = self;
    NSURLSessionConfiguration *sessionConf = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    AFHTTPSessionManager *sessionManager =
        [[AFHTTPSessionManager alloc] initWithBaseURL:nil sessionConfiguration:sessionConf];
    sessionManager.requestSerializer = [AFHTTPRequestSerializer serializer];
    sessionManager.responseSerializer = [AFJSONResponseSerializer serializer];
    [sessionManager POST:uploadUrl
        parameters:@{}
        constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
            for (NSString *fieldName in fields) {
                NSString *fieldValue = fields[fieldName];
                [formData appendPartWithFormData:[fieldValue dataUsingEncoding:NSUTF8StringEncoding] name:fieldName];
            }
            NSError *error;
            BOOL success = [formData appendPartWithFileURL:weakSelf.fileUrl
                                                      name:@"file"
                                                  fileName:weakSelf.fileUrl.lastPathComponent
                                                  mimeType:weakSelf.mimeType
                                                     error:&error];
            if (!success || error) {
                DDLogError(@"%@ failed: %@, error: %@", weakSelf.logTag, uploadUrl, error);
            }
        }
        progress:nil
        success:^(NSURLSessionDataTask *task, id _Nullable responseObject) {
            DDLogVerbose(@"%@ Response: %@, %@", weakSelf.logTag, uploadUrl, responseObject);

            NSString *urlString = [NSString stringWithFormat:@"https://debuglogs.org/%@", uploadKey];
            [self succeedWithUrl:[NSURL URLWithString:urlString]];
        }
        failure:^(NSURLSessionDataTask *_Nullable task, NSError *error) {
            DDLogError(@"%@ failed: %@", weakSelf.logTag, uploadUrl);
            [weakSelf failWithError:error];
        }];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

    NSInteger statusCode = httpResponse.statusCode;
    // We'll accept any 2xx status code.
    NSInteger statusCodeClass = statusCode - (statusCode % 100);
    if (statusCodeClass != 200) {
        DDLogError(@"%@ statusCode: %zd, %zd", self.logTag, statusCode, statusCodeClass);
        DDLogError(@"%@ headers: %@", self.logTag, httpResponse.allHeaderFields);
        [self failWithError:[NSError errorWithDomain:@"PastelogKit"
                                                code:10001
                                            userInfo:@{ NSLocalizedDescriptionKey : @"Invalid response code." }]];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    [self failWithError:error];
}

- (void)failWithError:(NSError *)error
{
    OWSAssert(error);

    DDLogError(@"%@ %s %@", self.logTag, __PRETTY_FUNCTION__, error);

    DispatchMainThreadSafe(^{
        // Call the completions exactly once.
        if (self.failure) {
            self.failure(self, error);
        }
        self.success = nil;
        self.failure = nil;
    });
}

- (void)succeedWithUrl:(NSURL *)url
{
    OWSAssert(url);

    DDLogVerbose(@"%@ %s %@", self.logTag, __PRETTY_FUNCTION__, url);

    DispatchMainThreadSafe(^{
        // Call the completions exactly once.
        if (self.success) {
            self.success(self, url);
        }
        self.success = nil;
        self.failure = nil;
    });
}

@end

#pragma mark -

@interface Pastelog () <UIAlertViewDelegate>

@property (nonatomic) UIAlertController *loadingAlert;

@property (nonatomic) DebugLogUploader *currentUploader;

@end

#pragma mark -

@implementation Pastelog

+ (instancetype)sharedManager
{
    static Pastelog *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    return self;
}

+ (void)submitLogs
{
    [self submitLogsWithCompletion:nil];
}

+ (void)submitLogsWithCompletion:(nullable SubmitDebugLogsCompletion)completionParam
{
    SubmitDebugLogsCompletion completion = ^{
        if (completionParam) {
            // Wait a moment. If PasteLog opens a URL, it needs a moment to complete.
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), completionParam);
        }
    };

    [self uploadLogsWithSuccess:^(NSURL *url) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_TITLE", @"Title of the debug log alert.")
                             message:NSLocalizedString(@"DEBUG_LOG_ALERT_MESSAGE", @"Message of the debug log alert.")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
                             actionWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_OPTION_EMAIL",
                                                 @"Label for the 'email debug log' option of the the debug log alert.")
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *_Nonnull action) {
                                         [Pastelog.sharedManager submitEmail:url];

                                         completion();
                                     }]];
        [alert addAction:[UIAlertAction
                             actionWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_OPTION_COPY_LINK",
                                                 @"Label for the 'copy link' option of the the debug log alert.")
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *_Nonnull action) {
                                         UIPasteboard *pb = [UIPasteboard generalPasteboard];
                                         [pb setString:url.absoluteString];

                                         completion();
                                     }]];
#ifdef DEBUG
        [alert addAction:[UIAlertAction
                             actionWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_OPTION_SEND_TO_SELF",
                                                 @"Label for the 'send to self' option of the the debug log alert.")
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *_Nonnull action) {
                                         [Pastelog.sharedManager sendToSelf:url];
                                     }]];
        [alert
            addAction:[UIAlertAction
                          actionWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_OPTION_SEND_TO_LAST_THREAD",
                                              @"Label for the 'send to last thread' option of the the debug log alert.")
                                    style:UIAlertActionStyleDefault
                                  handler:^(UIAlertAction *_Nonnull action) {
                                      [Pastelog.sharedManager sendToMostRecentThread:url];
                                  }]];
#endif
        [alert
            addAction:[UIAlertAction
                          actionWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_OPTION_BUG_REPORT",
                                              @"Label for the 'Open a Bug Report' option of the the debug log alert.")
                                    style:UIAlertActionStyleCancel
                                  handler:^(UIAlertAction *_Nonnull action) {
                                      [Pastelog.sharedManager prepareRedirection:url completion:completion];
                                  }]];
        UIViewController *presentingViewController
            = UIApplication.sharedApplication.frontmostViewControllerIgnoringAlerts;
        [presentingViewController presentViewController:alert animated:NO completion:nil];
    }];
}

+ (void)uploadLogsWithSuccess:(nullable UploadDebugLogsSuccess)success
{
    OWSAssert(success);

    [[self sharedManager] uploadLogsWithSuccess:success
                                        failure:^(NSString *localizedErrorMessage) {
                                            [Pastelog showFailureAlertWithMessage:localizedErrorMessage];
                                        }];
}

- (void)uploadLogsWithSuccess:(nullable UploadDebugLogsSuccess)successParam failure:(UploadDebugLogsFailure)failureParam
{
    OWSAssert(successParam);
    OWSAssert(failureParam);

    // Ensure that we call the completions on the main thread.
    UploadDebugLogsSuccess success = ^(NSURL *url) {
        if (successParam) {
            DispatchMainThreadSafe(^{
                successParam(url);
            });
        }
    };
    UploadDebugLogsFailure failure = ^(NSString *localizedErrorMessage) {
        DispatchMainThreadSafe(^{
            failureParam(localizedErrorMessage);
        });
    };

    // Phase 1. Make a local copy of all of the log files.
    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    [dateFormatter setLocale:[NSLocale currentLocale]];
    [dateFormatter setDateFormat:@"yyyy.MM.dd hh.mm.ss"];
    NSString *dateString = [dateFormatter stringFromDate:[NSDate new]];
    NSString *logsName = [[dateString stringByAppendingString:@" "] stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *tempDirectory = NSTemporaryDirectory();
    NSString *zipFilePath =
        [tempDirectory stringByAppendingPathComponent:[logsName stringByAppendingPathExtension:@"zip"]];
    NSString *zipDirPath = [tempDirectory stringByAppendingPathComponent:logsName];
    [OWSFileSystem ensureDirectoryExists:zipDirPath];
    [OWSFileSystem protectFileOrFolderAtPath:zipDirPath];

    NSArray<NSString *> *logFilePaths = DebugLogger.sharedLogger.allLogFilePaths;
    if (logFilePaths.count < 1) {
        failure(NSLocalizedString(@"DEBUG_LOG_ALERT_NO_LOGS", @"Error indicating that no debug logs could be found."));
        return;
    }

    for (NSString *logFilePath in logFilePaths) {
        NSString *copyFilePath = [zipDirPath stringByAppendingPathComponent:logFilePath.lastPathComponent];
        NSError *error;
        [[NSFileManager defaultManager] copyItemAtPath:logFilePath toPath:copyFilePath error:&error];
        if (error) {
            failure(NSLocalizedString(
                @"DEBUG_LOG_ALERT_COULD_NOT_COPY_LOGS", @"Error indicating that the debug logs could not be copied."));
            return;
        }
        [OWSFileSystem protectFileOrFolderAtPath:copyFilePath];
    }

    // Phase 2. Zip up the log files.
    BOOL zipSuccess =
        [SSZipArchive createZipFileAtPath:zipFilePath withContentsOfDirectory:zipDirPath withPassword:nil];
    if (!zipSuccess) {
        failure(NSLocalizedString(
            @"DEBUG_LOG_ALERT_COULD_NOT_PACKAGE_LOGS", @"Error indicating that the debug logs could not be packaged."));
        return;
    }

    [OWSFileSystem protectFileOrFolderAtPath:zipFilePath];
    [OWSFileSystem deleteFile:zipDirPath];

    // Phase 3. Upload the log files.

    __weak Pastelog *weakSelf = self;
    self.currentUploader = [DebugLogUploader new];
    [self.currentUploader uploadFileWithURL:[NSURL fileURLWithPath:zipFilePath]
        mimeType:@"application/zip"
        success:^(DebugLogUploader *uploader, NSURL *url) {
            if (uploader != weakSelf.currentUploader) {
                // Ignore events from obsolete uploaders.
                return;
            }
            [OWSFileSystem deleteFile:zipFilePath];
            success(url);
        }
        failure:^(DebugLogUploader *uploader, NSError *error) {
            if (uploader != weakSelf.currentUploader) {
                // Ignore events from obsolete uploaders.
                return;
            }
            [OWSFileSystem deleteFile:zipFilePath];
            failure(NSLocalizedString(
                @"DEBUG_LOG_ALERT_ERROR_UPLOADING_LOG", @"Error indicating that a debug log could not be uploaded."));
        }];
}

+ (void)showFailureAlertWithMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"DEBUG_LOG_ALERT_TITLE",
                                     @"Title of the alert shown for failures while uploading debug logs.")
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    UIViewController *presentingViewController = UIApplication.sharedApplication.frontmostViewControllerIgnoringAlerts;
    [presentingViewController presentViewController:alert animated:NO completion:nil];
}

#pragma mark Logs submission

- (void)submitEmail:(NSURL *)url
{
    NSString *emailAddress = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LOGS_EMAIL"];

    NSString *urlString = [NSString stringWithString: [[NSString stringWithFormat:@"mailto:%@?subject=iOS%%20Debug%%20Log&body=", emailAddress] stringByAppendingString:[[NSString stringWithFormat:@"Log URL: %@ \n Tell us about the issue: ", url]stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding]]];

    [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlString]];
}

- (void)prepareRedirection:(NSURL *)url completion:(SubmitDebugLogsCompletion)completion
{
    OWSAssert(completion);

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    [pb setString:url.absoluteString];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:NSLocalizedString(@"DEBUG_LOG_GITHUB_ISSUE_ALERT_TITLE",
                                                        @"Title of the alert before redirecting to Github Issues.")
                                            message:NSLocalizedString(@"DEBUG_LOG_GITHUB_ISSUE_ALERT_MESSAGE",
                                                        @"Message of the alert before redirecting to Github Issues.")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
                         actionWithTitle:NSLocalizedString(@"OK", @"")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                     [UIApplication.sharedApplication
                                         openURL:[NSURL URLWithString:[[NSBundle mainBundle]
                                                                          objectForInfoDictionaryKey:@"LOGS_URL"]]];

                                     completion();
                                 }]];
    UIViewController *presentingViewController = UIApplication.sharedApplication.frontmostViewControllerIgnoringAlerts;
    [presentingViewController presentViewController:alert animated:NO completion:nil];
}

- (void)sendToSelf:(NSURL *)url
{
    if (![TSAccountManager isRegistered]) {
        return;
    }
    NSString *recipientId = [TSAccountManager localNumber];
    OWSMessageSender *messageSender = Environment.current.messageSender;

    DispatchMainThreadSafe(^{
        __block TSThread *thread = nil;
        [TSStorageManager.dbReadWriteConnection
            readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
                thread = [TSContactThread getOrCreateThreadWithContactId:recipientId transaction:transaction];
            }];
        [ThreadUtil sendMessageWithText:url.absoluteString inThread:thread messageSender:messageSender];
    });

    // Also copy to pasteboard.
    [[UIPasteboard generalPasteboard] setString:url.absoluteString];
}

- (void)sendToMostRecentThread:(NSURL *)url
{
    if (![TSAccountManager isRegistered]) {
        return;
    }
    OWSMessageSender *messageSender = Environment.current.messageSender;

    DispatchMainThreadSafe(^{
        __block TSThread *thread = nil;
        [TSStorageManager.dbReadWriteConnection
            readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
                thread = [[transaction ext:TSThreadDatabaseViewExtensionName] firstObjectInGroup:[TSThread collection]];
            }];
        [ThreadUtil sendMessageWithText:url.absoluteString inThread:thread messageSender:messageSender];
    });

    // Also copy to pasteboard.
    [[UIPasteboard generalPasteboard] setString:url.absoluteString];
}

@end

NS_ASSUME_NONNULL_END
