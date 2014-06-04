// Copyright (c) 2013 TopCoder. All rights reserved.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//
//  SynchronizationServiceImpl.m
//  ISSFoodIntakeTracker
//
//  Created by LokiYang,supercharger on 2013-07-27.
//
//  Updated by pvmagacho on 04/19/2014
//  F2Finish - NASA iPad App Updates
//

#import "SynchronizationServiceImpl.h"
#import "LocalClientImpl.h"
#import "UserServiceImpl.h"
#import "FoodConsumptionRecordServiceImpl.h"
#import "FoodProductServiceImpl.h"
#import "Models.h"
#import "parseCSV.h"
#import "LoggingHelper.h"
#import "DataHelper.h"
#import "Settings.h"
#import "AppDelegate.h"

@implementation SynchronizationServiceImpl

@synthesize localFileSystemDirectory = _localFileSystemDirectory;
@synthesize voiceRecordingFileNameSuffix = _voiceRecordingFileNameSuffix;
@synthesize imageFileNameSuffix = _imageFileNameSuffix;


#define CHECK_ERROR_AND_RETURN(error, return_error, error_msg, error_code, unlock_context, undo_context) \
    if (error) {\
        if (return_error) {\
            *return_error = [NSError errorWithDomain:@"SynchronizationService" code:error_code\
            userInfo:@{NSUnderlyingErrorKey:error_msg}];\
        }\
        if (undo_context) {\
            [self undo];\
        }\
        if (unlock_context) {\
            [[self managedObjectContext] unlock];\
        }\
        [LoggingHelper logMethodExit:methodName returnValue:@NO];\
        return NO;\
    }

/*!
 @discussion Initialize the class instance with NSManagedObjectContext and configuration.
 * @param context The NSManagedObjectContext.
 * @param configuration The configuration.
 * @return The newly created object.
 */
-(id)initWithConfiguration:(NSDictionary *)configuration {
    self = [super initWithConfiguration:configuration];
    
    if(self) {
        _localFileSystemDirectory = [configuration valueForKey:@"LocalFileSystemDirectory"];
        _imageFileNameSuffix = [configuration valueForKey:@"ImageFileNameSuffix"];
        _voiceRecordingFileNameSuffix = [configuration valueForKey:@"VoiceRecordingFileNameSuffix"];
    }
    return self;
}

/*!
 @discussion This method will get all non synchronized entity objects.
 @return Current Timestamp in long.
 */
- (long long)getLastSynchronizedTime{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *lastSyncTime = [defaults objectForKey:@"LastSynchronizedTime"];
    if(lastSyncTime != nil) {
        [[NSNotificationCenter defaultCenter] postNotificationName:UpdateLastSync
                                                            object:[NSDate
                                                                    dateWithTimeIntervalSince1970:[lastSyncTime longLongValue]/1000]];
        
        return [lastSyncTime longLongValue];    
    }
    return 0;
}

-(void)updateSyncTime:(long long)timestamp {
    NSNumber *syncTime = [NSNumber numberWithLongLong:timestamp];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:syncTime forKey:@"LastSynchronizedTime"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:UpdateLastSync
                                                        object:[NSDate dateWithTimeIntervalSince1970:timestamp/1000]];
    return;
}

/*!
 @discussion This method will get all non synchronized entity objects.
 @param entityName The object's entity name.
 @param error The error.
 @return A NSArray contains objects.
 */
- (NSArray *)getNonSynchronizedObject:(NSString *)entityName error:(NSError **)error {
    [self.managedObjectContext lock];
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(synchronized == NO)"];
    NSEntityDescription *description = [NSEntityDescription  entityForName:entityName
                                                    inManagedObjectContext:[self managedObjectContext]];
    [request setEntity:description];
    [request setPredicate:predicate];
    [request setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"lastModifiedDate" ascending:YES]]];
    NSArray *results = [[self managedObjectContext] executeFetchRequest:request error:error];
    [self.managedObjectContext unlock];
    return results;
}

- (void) updateProgress:(NSNumber *)progress {
    NSDictionary *progressParam = @{@"progress": progress};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InitialLoadingProgressEvent" object:progressParam];
}

/*!
 @discussion This method will be used to synchronize the data. If the iPad device is currently not connected
 to Wi-Fi network, then this method will do nothing.
 @parame error The NSError object if any error occurred during the operation
 @return YES if the operation succceeds, otherwise NO.
 */
-(BOOL)synchronize:(NSError **)error{
    NSString *methodName = [NSString stringWithFormat:@"%@.synchronize:", NSStringFromClass(self.class)];
  
    [LoggingHelper logMethodEntrance:methodName paramNames:@[@"synchronize:"] params:nil];
    
    // Create localClient and connect to the shared file server
    NSError *e = nil;
    id<LocalClient> localClient = [self createLocalClient];
    CHECK_ERROR_AND_RETURN(e, error, @"Cannot create localClient.", ConnectionErrorCode, YES, NO);

    // Lock on the managedObjectContext
    [[self managedObjectContext] lock];
    
     
    // Update progress
    [self updateProgress:@0.5];

    // ARS 1.1.3 #1.Create an NSMutableArray to store the image/voice recording file paths to transfer
    // to Shared File Server.
    [self startUndoActions];
    NSMutableData *userCSVData = [NSMutableData data];
     
    // ARS 1.1.3 #3 5.Query any local Core Data User objects with isSynchronized == NO, and for each of the User objects
    //  o   Write a line for the object according to the file format specified in /data_sync_files/User.csv
    //  o   Add all relevant file paths to the NSMutableArray created in step 2.
    //  o   If deleted property of the object is YES, then physically delete the object from local Core Data
    //      managed object context, otherwise change its isSynchronized property to YES.
    NSArray *usersToPush = [self getNonSynchronizedObject:@"User" error:&e];
    CHECK_ERROR_AND_RETURN(e, error, @"Cannot fetch users to be pushed.", EntityNotFoundErrorCode, YES, YES);
    
    NSArray *foodProductsToPush = [self getNonSynchronizedObject:@"AdhocFoodProduct" error:&e];
    CHECK_ERROR_AND_RETURN(e, error, @"Cannot fetch AdhocFoodProducts to be pushed.",
                           EntityNotFoundErrorCode, YES, YES);
    
    NSArray *foodConsumptionRecordsToPush = [self getNonSynchronizedObject:@"FoodConsumptionRecord" error:&e];
    CHECK_ERROR_AND_RETURN(e, error, @"Cannot fetch FoodConsumptionRecords to be pushed.",
                           EntityNotFoundErrorCode, YES, YES);
    
    long long lastSyncedTimeinMillis = [self getLastSynchronizedTime];
    long long currentSyncTimeinMillis = 0;
    
    if([usersToPush count] != 0 || [foodProductsToPush count] != 0 || [foodConsumptionRecordsToPush count] != 0) {
        AppDelegate *appDelegate = (AppDelegate*) [[UIApplication sharedApplication] delegate];
    
        NSTimeInterval currentTimeInterval = [[NSDate date] timeIntervalSince1970];
        currentSyncTimeinMillis =  (long long)(currentTimeInterval * 1000.0);
        NSString* timestamp = [NSString stringWithFormat:@"%llu",currentSyncTimeinMillis];
        
        [localClient createDirectory:[NSString stringWithFormat:@"data_sync/%@",timestamp] error:&e];
        CHECK_ERROR_AND_RETURN(e, error, @"Cannot create directory with the current timestamp as a name in 'data_sync' directory.",
                               SynchronizationErrorCode, YES, YES);
        
        [localClient createDirectory:[NSString stringWithFormat:@"data_sync/%@/data",timestamp] error:&e];
        CHECK_ERROR_AND_RETURN(e, error, @"Cannot create data directory.", SynchronizationErrorCode, YES, YES);
        
        [localClient createDirectory:[NSString stringWithFormat:@"data_sync/%@/media",timestamp] error:&e];
        CHECK_ERROR_AND_RETURN(e, error, @"Cannot create media directory.", SynchronizationErrorCode, YES, YES);
   
        BOOL isFolderCreated = NO;
        for (User* userToPush in usersToPush) {
            // Write a comma-separated line of the User to userCSVData, refer to ADS 1.1.3
            // and data_sync_files/User.csv for detailed format            
            NSString *csvLine = [NSString stringWithFormat:@"\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\","
                                 "\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%.0f\",\"%.0f\"\r\n",
                                 [userToPush.admin boolValue] == YES ? @"YES":@"NO",
                                 userToPush.fullName,
                                 userToPush.lastUsedFoodProductFilter == nil ? @"":
                                 (userToPush.lastUsedFoodProductFilter.name == nil ? @"" :
                                  userToPush.lastUsedFoodProductFilter.name),
                                 userToPush.lastUsedFoodProductFilter == nil ? @"":
                                 [DataHelper
                                  convertStringWrapperNSSetToNSString:userToPush.lastUsedFoodProductFilter.origins
                                  withSeparator:@";"],
                                 userToPush.lastUsedFoodProductFilter == nil ? @"":
                                 [DataHelper
                                  convertStringWrapperNSSetToNSString:userToPush.lastUsedFoodProductFilter.categories
                                  withSeparator:@";"],
                                 userToPush.lastUsedFoodProductFilter == nil ? @"":
                                 userToPush.lastUsedFoodProductFilter.favoriteWithinTimePeriod,
                                 userToPush.lastUsedFoodProductFilter == nil ? @"":
                                 [DataHelper formatFoodProductSortOptionToString:
                                  userToPush.lastUsedFoodProductFilter.sortOption],
                                 [userToPush.useLastUsedFoodProductFilter boolValue] == YES ? @"YES" :@"NO",
                                 userToPush.dailyTargetFluid,
                                 userToPush.dailyTargetEnergy,
                                 userToPush.dailyTargetSodium,
                                 userToPush.dailyTargetProtein,
                                 userToPush.dailyTargetCarb,
                                 userToPush.dailyTargetFat,
                                 userToPush.maxPacketsPerFoodProductDaily,
                                 userToPush.profileImage,
                                 [userToPush.deleted boolValue] == YES ? @"YES":@"NO",
                                 [userToPush.lastModifiedDate timeIntervalSince1970],
                                 [userToPush.createdDate timeIntervalSince1970]];
            NSData *csvLineByte = [csvLine dataUsingEncoding:NSUTF8StringEncoding];
            [userCSVData appendData:csvLineByte];
            
            if ([userToPush.deleted boolValue] == YES) {
                [[self managedObjectContext] deleteObject:userToPush];
            } else {
                userToPush.synchronized = @YES;
            }
            
            /* transfer additional files */
            if (userToPush.profileImage && ![appDelegate.mediaFiles containsObject:userToPush.profileImage]) {
                [localClient createDirectory:[NSString stringWithFormat:@"data_sync/%@/media/%@",timestamp, userToPush.fullName]
                                       error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot create media directory.", SynchronizationErrorCode, YES, YES);
                isFolderCreated = YES;
                
                NSString *localPath = [[DataHelper getAbsoulteLocalDirectory:self.localFileSystemDirectory]
                                       stringByAppendingPathComponent:userToPush.profileImage];
                NSString *smbPath = [NSString stringWithFormat:@"data_sync/%@/media/%@/%@", timestamp, userToPush.fullName, userToPush.profileImage];
                NSData *data = [NSData dataWithContentsOfFile:localPath];
                [localClient writeFile:smbPath data:data error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot copy local file to shared file server.",
                                       SynchronizationErrorCode, YES, YES);
                
                [appDelegate.mediaFiles addObject:userToPush.profileImage];
            }
        }
        
        // Update progress
        [self updateProgress:@0.55];
        
        // ARS 1.1.3 #5.Similarly, query and process local non-synchronized AdhocFoodProduct,
        // FoodConsumptionRecord and SummaryGenerationHistory objects
        NSMutableData *adhocFoodProductCSVData = [NSMutableData data];
        for (AdhocFoodProduct* foodProductToPush in foodProductsToPush) {
            // Write a comma-separated line of the User to adhocFoodProductCSVData, refer to ADS 1.1.3
            // and data_sync_files/AdhocFoodProduct.csv for detailed format
            NSString *csvLine = [NSString stringWithFormat:@"\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\","
                                 "\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%.0f\",\"%.0f\"\r\n",
                                 foodProductToPush.name,
                                 foodProductToPush.barcode == nil? @"" : foodProductToPush.barcode,
                                 [DataHelper convertStringWrapperNSSetToNSString:foodProductToPush.images
                                                                   withSeparator:@";"],
                                 foodProductToPush.origin,
                                 [DataHelper convertStringWrapperNSSetToNSString:foodProductToPush.categories
                                                                   withSeparator:@";"], foodProductToPush.fluid,
                                 foodProductToPush.energy,
                                 foodProductToPush.sodium,
                                 foodProductToPush.protein,
                                 foodProductToPush.carb,
                                 foodProductToPush.fat,
                                 foodProductToPush.productProfileImage,
                                 foodProductToPush.user.fullName,
                                 [foodProductToPush.deleted boolValue] == YES ? @"YES" : @"NO",
                                 [foodProductToPush.lastModifiedDate timeIntervalSince1970],
                                 [foodProductToPush.createdDate timeIntervalSince1970]];
            NSData *csvLineByte = [csvLine dataUsingEncoding:NSUTF8StringEncoding];
            [adhocFoodProductCSVData appendData:csvLineByte];
            
            if ([foodProductToPush.deleted boolValue] == YES) {
                [[self managedObjectContext] deleteObject:foodProductToPush];
            } else {
                foodProductToPush.synchronized = @YES;
            }
            
            NSMutableArray *additionalFiles = [NSMutableArray array];
            // Add image file paths of the food product to additionalFiles array
            for (StringWrapper *path in foodProductToPush.images) {
                if(path.value != nil && path.value.length != 0) {
                    [additionalFiles addObject:[path.value copy]];
                }
            }
            if (foodProductToPush.productProfileImage && foodProductToPush.productProfileImage.length != 0) {
                [additionalFiles addObject:foodProductToPush.productProfileImage];
            }
            
            if (!isFolderCreated && additionalFiles.count > 0) {
                [localClient createDirectory:[NSString stringWithFormat:@"data_sync/%@/media/%@",timestamp,
                                              foodProductToPush.user.fullName] error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot create media directory.", SynchronizationErrorCode, YES, YES);
                isFolderCreated = YES;
            }
            
            for (NSString *path in additionalFiles) {
                /* transfer additional files */
                if (![appDelegate.mediaFiles containsObject:path]) {
                    NSString *localPath = [[DataHelper getAbsoulteLocalDirectory:self.localFileSystemDirectory]
                                           stringByAppendingPathComponent:path];
                    NSString *smbPath = [NSString stringWithFormat:@"data_sync/%@/media/%@/%@", timestamp,
                                         foodProductToPush.user.fullName, path];
                    NSData *data = [NSData dataWithContentsOfFile:localPath];
                    [localClient writeFile:smbPath data:data error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot copy local file to shared file server.",
                                           SynchronizationErrorCode, YES, YES);
                    
                    [appDelegate.mediaFiles addObject:path];
                }
            }
        }
        
        // process FoodConsumptionRecord
        NSMutableData *foodConsumptionRecordCSVData = [NSMutableData data];
        for (FoodConsumptionRecord* foodConsumptionRecordToPush in foodConsumptionRecordsToPush) {
            // Write a comma-separated line of the User to foodConsumptionRecordCSVData, refer to ADS 1.1.3
            // and data_sync_files/FoodConsumptionRecord.csv for detailed format
            NSString *csvLine = [NSString stringWithFormat:@"\"%@\",\"%@\",\"%.0f\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\","
                                 "\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%@\",\"%.0f\",\"%.0f\",\"%@\"\r\n",
                                 foodConsumptionRecordToPush.foodProduct.name, foodConsumptionRecordToPush.user.fullName,
                                 [foodConsumptionRecordToPush.timestamp timeIntervalSince1970],
                                 foodConsumptionRecordToPush.quantity,
                                 foodConsumptionRecordToPush.comment == nil ?@"":foodConsumptionRecordToPush.comment,
                                 [DataHelper convertStringWrapperNSSetToNSString:foodConsumptionRecordToPush.images
                                                                   withSeparator:@";"],
                                 [DataHelper convertStringWrapperNSSetToNSString:foodConsumptionRecordToPush.voiceRecordings
                                                                   withSeparator:@";"],
                                 foodConsumptionRecordToPush.fluid,
                                 foodConsumptionRecordToPush.energy,
                                 foodConsumptionRecordToPush.sodium,
                                 foodConsumptionRecordToPush.protein,
                                 foodConsumptionRecordToPush.carb,
                                 foodConsumptionRecordToPush.fat,
                                 [foodConsumptionRecordToPush.deleted boolValue] == YES ? @"YES" :@"NO",
                                 [foodConsumptionRecordToPush.lastModifiedDate timeIntervalSince1970],
                                 [foodConsumptionRecordToPush.createdDate timeIntervalSince1970],
                                 foodConsumptionRecordToPush.savedObjectId];
            NSData *csvLineByte = [csvLine dataUsingEncoding:NSUTF8StringEncoding];
            [foodConsumptionRecordCSVData appendData:csvLineByte];
            
            if ([foodConsumptionRecordToPush.deleted boolValue] == YES) {
                [[self managedObjectContext] deleteObject:foodConsumptionRecordToPush];
            } else {
                foodConsumptionRecordToPush.synchronized = @YES;
            }
            
            // Add image file paths of the food consumption record to additionalFiles array
            NSMutableArray *additionalFiles = [NSMutableArray array];
            for (StringWrapper *path in foodConsumptionRecordToPush.images) {
                if(path.value != nil && path.value.length != 0) {
                    [additionalFiles addObject:[path.value copy]];
                }
            }
            // Add voice recording file paths of food consumption record .
            for (StringWrapper *path in foodConsumptionRecordToPush.voiceRecordings) {
                if(path.value != nil && path.value.length != 0) {
                    [additionalFiles addObject:[path.value copy]];
                }
            }
            
            if (!isFolderCreated && additionalFiles.count > 0) {
                [localClient createDirectory:[NSString stringWithFormat:@"data_sync/%@/media/%@",timestamp,
                                              foodConsumptionRecordToPush.user.fullName] error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot create media directory.", SynchronizationErrorCode, YES, YES);
                isFolderCreated = YES;
            }
            
            for (NSString *path in additionalFiles) {
                /* transfer additional files */
                if (![appDelegate.mediaFiles containsObject:path]) {
                    NSString *localPath = [[DataHelper getAbsoulteLocalDirectory:self.localFileSystemDirectory]
                                           stringByAppendingPathComponent:path];
                    NSString *smbPath = [NSString stringWithFormat:@"data_sync/%@/media/%@/%@", timestamp,
                                         foodConsumptionRecordToPush.user.fullName, path];
                    NSData *data = [NSData dataWithContentsOfFile:localPath];
                    [localClient writeFile:smbPath data:data error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot copy local file to shared file server.",
                                           SynchronizationErrorCode, YES, YES);
                    
                    [appDelegate.mediaFiles addObject:path];
                }
            }
        }
        
        // Update progress
        [self updateProgress:@0.6];
        
        // process SummaryGenerationHistory
        NSMutableData *summaryGenerationHistoryCSVData = [NSMutableData data];
        NSArray *summaryGenerationHistoriesToPush = [self getNonSynchronizedObject:@"SummaryGenerationHistory" error:&e];
        CHECK_ERROR_AND_RETURN(e, error, @"Cannot fetch SummaryGenerationHistory to be pushed.",
                               EntityNotFoundErrorCode, YES, YES);
        
        for (SummaryGenerationHistory* summaryGenerationHistoryToPush in summaryGenerationHistoriesToPush) {
            // Write a comma-separated line of the User to summaryGenerationHistoryCSVData, refer to ADS 1.1.3
            // and data_sync_files/SummaryGenerationHistory.csv for detailed format
            NSString *csvLine = [NSString stringWithFormat:@"\"%@\",\"%.0f\",\"%.0f\",\"%@\",\"%.0f\",\"%.0f\"\r\n",
                                 summaryGenerationHistoryToPush.user.fullName,
                                 [summaryGenerationHistoryToPush.startDate timeIntervalSince1970],
                                 [summaryGenerationHistoryToPush.endDate timeIntervalSince1970],
                                 [summaryGenerationHistoryToPush.deleted boolValue] == YES ? @"YES" : @"NO",
                                 [summaryGenerationHistoryToPush.lastModifiedDate timeIntervalSince1970],
                                 [summaryGenerationHistoryToPush.createdDate timeIntervalSince1970]];
            NSData *csvLineByte = [csvLine dataUsingEncoding:NSUTF8StringEncoding];
            [summaryGenerationHistoryCSVData appendData:csvLineByte];
            
            if ([summaryGenerationHistoryToPush.deleted boolValue] == YES) {
                [[self managedObjectContext] deleteObject:summaryGenerationHistoryToPush];
            } else {
                summaryGenerationHistoryToPush.synchronized = @YES;
            }
        }
        
        // Transfer CSV files and additional files to Shared File Server
        // ARS 1.1.3 #4.reate a CSV file named "User.csv"
        if (usersToPush.count > 0) {
            [localClient writeFile:[NSString stringWithFormat:@"data_sync/%@/data/User.csv", timestamp]
                            data:userCSVData error:&e];
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot write User.csv to shared file server.",
                                   SynchronizationErrorCode, YES, YES);
        }
        
        if (foodProductsToPush.count > 0) {
            [localClient writeFile:[NSString stringWithFormat:@"data_sync/%@/data/AdhocFoodProduct.csv", timestamp]
                            data:adhocFoodProductCSVData error:&e];
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot write AdhocFoodProduct.csv to shared file server.",
                                   SynchronizationErrorCode, YES, YES);
        }
        
        if (foodConsumptionRecordsToPush.count > 0) {
            [localClient writeFile:[NSString stringWithFormat:@"data_sync/%@/data/FoodConsumptionRecord.csv",
                                   timestamp] data:foodConsumptionRecordCSVData error:&e];
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot write FoodConsumptionRecord.csv to shared file server.",
                                   SynchronizationErrorCode, YES, YES);
        }
        
        if (summaryGenerationHistoriesToPush.count > 0) {
            [localClient writeFile:[NSString stringWithFormat:@"data_sync/%@/data/SummaryGenerationHistory.csv",
                                  timestamp] data:summaryGenerationHistoryCSVData error:&e];
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot write SummaryGenerationHistory.csv to shared file server.",
                                   SynchronizationErrorCode, YES, YES);
        }
        
        // NOTE if any error occurred during steps 2 – 8, local data changes in Core Data should be reverted.
        [self endUndoActions];
        [self updateSyncTime:currentSyncTimeinMillis];
    }
    
    // Update progress
    [self updateProgress:@0.65];

    // ARS 1.1.3 #9.Scan data changes from other iPad devices, for each /data_sync/<TIMESTAMP>/data
    // directory
    NSArray* dataSyncSubDirectories = [localClient listDirectories:@"data_sync" error:&e];
    CHECK_ERROR_AND_RETURN(e, error, @"Cannot list 'data_sync' directory.", SynchronizationErrorCode, YES, NO);
    
    NSFetchRequest *request = nil;
    NSPredicate *predicate = nil;
    NSEntityDescription *description = nil;
    
    // Calculate the the delta progress
    float currentProgress = 0.65;
    float progressDelta = 0.35;
    int count = 0;
    NSMutableArray *subDirectoriesToSync = [NSMutableArray array];

    for (NSString *timestampDir in dataSyncSubDirectories) {
        long long timeStampFromDir = [timestampDir longLongValue];
        if (timeStampFromDir > lastSyncedTimeinMillis &&
            timeStampFromDir != currentSyncTimeinMillis) {
            
            [subDirectoriesToSync addObject:timestampDir];
            count++;
        }
    }
    if (count > 0) {
        progressDelta /= (count * 3);
        // order by timestamp
        [subDirectoriesToSync sortUsingFunction:sortByTimestamp context:NULL];
    }
    
    NSLog(@" -->> Loading %d folders out of %d <<-- ", count, dataSyncSubDirectories.count);

    for (NSString *subDirectory in subDirectoriesToSync) {
        // Not applied this sync yet
        // Pull and parse User.csv
        NSData *data = nil;
        data = [localClient readFile:[NSString stringWithFormat:@"data_sync/%@/data/User.csv", subDirectory] error:&e];
        if (!data) {
            continue;
        }
        CHECK_ERROR_AND_RETURN(e, error, @"Cannot read 'User.csv'.", SynchronizationErrorCode, YES, NO);

        CSVParser *parser = [CSVParser new];
        NSMutableArray *userDataArray = [parser parseData:data];
        for (NSMutableArray* userData in userDataArray) {
            if (userData.count < 18) {
                continue;
            }
            
            NSString *username = userData[1];
            // Try to fetch existing User with the username from Core Data managedObjectContext
            request = [[NSFetchRequest alloc] init];
            predicate = [NSPredicate predicateWithFormat:@"(deleted == NO) AND (fullName == %@)", username];
            description = [NSEntityDescription entityForName:@"User"
                                      inManagedObjectContext:[self managedObjectContext]];
            [request setEntity:description];
            [request setPredicate:predicate];
            NSArray *localUsers = [[self managedObjectContext] executeFetchRequest:request error:&e];
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot fetch local users in managed object context.",
                                   EntityNotFoundErrorCode, YES, NO);
            id<UserService> userService = [[UserServiceImpl alloc] init];
            if ([localUsers count] > 0) {
                User *localUser = localUsers[0];
                int index = userData.count > 19 ? 17 : 16;
                BOOL deleted = [userData[index] boolValue];
                if (deleted) {
                    [[self managedObjectContext] deleteObject:localUser];
                } else {
                    // Extract other properties from userData array, and update the localUser object
                    // refer to ADS 1.1.3 and data_sync_files/User.csv for detailed format
                    User *user = [DataHelper buildUserFromData:userData
                                        inManagedObjectContext:self.managedObjectContext error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot build user.",
                                           SynchronizationErrorCode, YES, NO);
                    //[[self managedObjectContext] deleteObject:localUser];
                    // saveUser will update existing user or save new user.
                    FoodProductFilter *filter = user.lastUsedFoodProductFilter;
                    user.lastUsedFoodProductFilter = nil;
                    NSDate *createDate = user.createdDate;
                    NSDate *modifyDate = user.lastModifiedDate;
                    [userService saveUser:user error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot save user.",
                                           SynchronizationErrorCode, YES, NO);
                    if(filter != nil) {
                        id<FoodProductService> foodService = [[FoodProductServiceImpl alloc]init];
                        [foodService filterFoodProducts:localUser filter:filter error:&e];
                        CHECK_ERROR_AND_RETURN(e, error, @"Cannot save filter.",
                                               SynchronizationErrorCode, YES, NO);
                        localUser.lastUsedFoodProductFilter.createdDate = filter.createdDate;
                        localUser.lastUsedFoodProductFilter.lastModifiedDate = filter.lastModifiedDate;
                        localUser.lastUsedFoodProductFilter.synchronized = @YES;
                    }
                    localUser.lastModifiedDate = modifyDate;
                    localUser.createdDate = createDate;
                    localUser.synchronized = @YES;
                    
                }
            } else {
                // Create a new User in Core Data managedObjectContext
                // Extract other properties from userData array, and set the properties to the new object
                User *user = [DataHelper buildUserFromData:userData
                                    inManagedObjectContext:self.managedObjectContext error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot build user.", SynchronizationErrorCode, YES, NO);
                FoodProductFilter *filter = user.lastUsedFoodProductFilter;
                user.lastUsedFoodProductFilter = nil;
                NSDate *createDate = user.createdDate;
                NSDate *modifyDate = user.lastModifiedDate;
                // saveUser will update existing user or save new user.
                [userService saveUser:user error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot save user.", SynchronizationErrorCode,YES, NO);
                if(filter != nil) {
                    id<FoodProductService> foodService = [[FoodProductServiceImpl alloc] init];
                    [foodService filterFoodProducts:user filter:filter error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot save filter.",
                                           SynchronizationErrorCode, YES, NO);
                    user.lastUsedFoodProductFilter.createdDate = filter.createdDate;
                    user.lastUsedFoodProductFilter.lastModifiedDate = filter.lastModifiedDate;
                    user.lastUsedFoodProductFilter.synchronized = @YES;
                }
                user.lastModifiedDate = modifyDate;
                user.createdDate = createDate;
                user.synchronized = @YES;
            }
        }
        
        // Save changes in the managedObjectContext
        [[self managedObjectContext] save:&e];
        CHECK_ERROR_AND_RETURN(e, error, @"Cannot save managed object context.", SynchronizationErrorCode, YES, NO);
        
        // Update progress
        currentProgress += progressDelta;
        [self updateProgress:[NSNumber numberWithFloat:currentProgress]];
    }
    
    // Check media folders
    for (NSString *subDirectory in subDirectoriesToSync) {
        // Read image/voice recording files in /data and save in local file system
        NSString *folder = @"media";
        NSArray* dataFiles = [localClient listFiles:[NSString stringWithFormat:@"data_sync/%@/%@/", subDirectory, folder] error:&e];
        if (!dataFiles) {
            // legacy data
            e = nil;
            folder = @"data";
            dataFiles = [localClient listFiles:[NSString stringWithFormat:@"data_sync/%@/%@/", subDirectory, folder] error:&e];
            
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot list image and voice recording files.", SynchronizationErrorCode, YES, NO);
            for (NSString *dataFile in dataFiles) {
                if ([dataFile hasSuffix:self.imageFileNameSuffix] || [dataFile hasSuffix:self.voiceRecordingFileNameSuffix]) {
                    NSString *localDataFile = [[DataHelper getAbsoulteLocalDirectory:self.localFileSystemDirectory]
                                               stringByAppendingPathComponent:dataFile];
                    NSData *data = [localClient readFile: [NSString stringWithFormat:@"data_sync/%@/%@/%@", subDirectory, folder, dataFile] error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot read image and recording file.",
                                           SynchronizationErrorCode, YES, NO);
                    [data writeToFile:localDataFile atomically:YES];
                }
            }
        } else {
            CHECK_ERROR_AND_RETURN(e, error, @"Cannot list image and voice recording files.", SynchronizationErrorCode, YES, NO);
            
            NSArray* folders = [localClient listDirectories:[NSString stringWithFormat:@"data_sync/%@/%@/", subDirectory, folder] error:&e];
            for (NSString *innerFolder in folders) {
                dataFiles = [localClient listFiles:[NSString stringWithFormat:@"data_sync/%@/%@/%@", subDirectory, folder, innerFolder] error:&e];
                for (NSString *dataFile in dataFiles) {
                    if ([dataFile hasSuffix:self.imageFileNameSuffix] || [dataFile hasSuffix:self.voiceRecordingFileNameSuffix]) {
                        NSString *localDataFile = [[DataHelper getAbsoulteLocalDirectory:self.localFileSystemDirectory]
                                                   stringByAppendingPathComponent:dataFile];
                        NSData *data = [localClient readFile: [NSString stringWithFormat:@"data_sync/%@/%@/%@/%@", subDirectory, folder, innerFolder, dataFile] error:&e];
                        CHECK_ERROR_AND_RETURN(e, error, @"Cannot read image and recording file.",
                                               SynchronizationErrorCode, YES, NO);
                        [data writeToFile:localDataFile atomically:YES];
                    }
                }
            }
        }
        
        // Update progress
        currentProgress += progressDelta;
        [self updateProgress:[NSNumber numberWithFloat:currentProgress]];
    }
    
    for (NSString *subDirectory in subDirectoriesToSync) {
        // Similarly, pull and process AdhocFoodProduct.csv, FoodConsumptionRecord.csv,
        // SummaryGenerationHistory.csv files
        
        // process AdhocFoodProduct.csv
        NSData *data = [localClient readFile:[NSString stringWithFormat:@"data_sync/%@/data/AdhocFoodProduct.csv", subDirectory] error:&e];
        CSVParser *parser = [CSVParser new];
        NSMutableArray *adhocFoodProductDataArray = [parser parseData:data];
        for (NSMutableArray* adhocFoodProductData in adhocFoodProductDataArray) {
            if (adhocFoodProductData.count < 16) {
                continue;
            }
            
            NSString *username = adhocFoodProductData[12];
            NSString *foodProductName = [[adhocFoodProductData[0]
                                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                         stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
            NSFetchRequest *request = [[NSFetchRequest alloc] init];
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(fullName == %@)", username];
            NSEntityDescription *description = [NSEntityDescription entityForName:@"User"
                                                           inManagedObjectContext:self.managedObjectContext];
            [request setEntity:description];
            [request setPredicate:predicate];
            NSArray *localUsers = [self.managedObjectContext executeFetchRequest:request error:&e];
            if(localUsers == nil || localUsers.count == 0) {
                NSString *errorMsg = [NSString stringWithFormat:@"Cannot find user %@ for AdhocFoodProduct.", username];
                /*e = [NSError errorWithDomain:@"SychronizationService"
                                        code: EntityNotFoundErrorCode
                                    userInfo:@{NSLocalizedDescriptionKey:erroMsg}];
                
                CHECK_ERROR_AND_RETURN(e, error, errorMsg, EntityNotFoundErrorCode, YES, NO);*/
                e = nil;
                NSLog(@"Warning: %@", errorMsg);
                continue;
            }
            
            // Try to fetch existing AdhocFoodProduct with the username and name from
            // Core Data managedObjectContext
            request = [[NSFetchRequest alloc] init];
            predicate = [NSPredicate predicateWithFormat:@"(deleted == NO) AND (user.fullName == %@) " "AND (name == %@)",
                         username, foodProductName];
            description = [NSEntityDescription entityForName:@"AdhocFoodProduct" inManagedObjectContext:[self managedObjectContext]];
            [request setEntity:description];
            [request setPredicate:predicate];
            NSArray *localAdhocFoodProducts = [[self managedObjectContext] executeFetchRequest:request error:&e];
            if ([localAdhocFoodProducts count] > 0) {
                AdhocFoodProduct *localFoodProduct = localAdhocFoodProducts[0];
                BOOL deleted = [adhocFoodProductData[13] boolValue];
                if (deleted) {
                    [[self managedObjectContext] deleteObject:localFoodProduct];
                } else {
                    // Extract other properties from adhocFoodProductData array, and update the
                    // localFoodProduct object
                    // refer to ADS 1.1.3 and data_sync_files/AdhocFoodProduct.csv for detailed format
                    AdhocFoodProduct *foodProduct = [DataHelper
                                                     buildAdhocFoodProductFromData:adhocFoodProductData
                                                     inManagedObjectContext:self.managedObjectContext
                                                     error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot build AdhocFoodProduct.",
                                           SynchronizationErrorCode, YES, NO);
                    [self.managedObjectContext deleteObject:localFoodProduct];
                    
                    id<FoodProductService> foodService = [[FoodProductServiceImpl alloc] init];
                    NSDate *createDate = foodProduct.createdDate;
                    NSDate *modifyDate = foodProduct.lastModifiedDate;
                    [foodService addAdhocFoodProduct:localUsers[0] product:foodProduct error:&e];
                    foodProduct.lastModifiedDate = modifyDate;
                    foodProduct.createdDate = createDate;
                    foodProduct.synchronized = @YES;
                    
                }
            } else {
                // Create a new AdhocFoodProduct in Core Data managedObjectContext
                // Extract other properties from adhocFoodProductData array, and set the properties to
                // the new AdhocFoodProduct object
                AdhocFoodProduct *foodProduct = [DataHelper
                                                 buildAdhocFoodProductFromData:adhocFoodProductData
                                                 inManagedObjectContext:self.managedObjectContext error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot build AdhocFoodProduct.",
                                       SynchronizationErrorCode, YES, NO);
                
                id<FoodProductService> foodService = [[FoodProductServiceImpl alloc] init];
                NSDate *createDate = foodProduct.createdDate;
                NSDate *modifyDate = foodProduct.lastModifiedDate;
                [foodService addAdhocFoodProduct:localUsers[0] product:foodProduct error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot save AdhocFoodProduct.",
                                       SynchronizationErrorCode, YES, NO);
                foodProduct.lastModifiedDate = modifyDate;
                foodProduct.createdDate = createDate;
                foodProduct.synchronized = @YES;
            }
        }
        
        // Update progress
        currentProgress += (progressDelta / 3);
        [self updateProgress:[NSNumber numberWithFloat:currentProgress]];
        
        // Process FoodConsumptionRecord.csv
        data = [localClient readFile:[NSString stringWithFormat:@"data_sync/%@/data/FoodConsumptionRecord.csv", subDirectory] error:&e];
        
        NSMutableArray *foodConsumptionRecordDataArray = [parser parseData:data];
        for (NSMutableArray* foodRecordData in foodConsumptionRecordDataArray) {
            if (foodRecordData.count < 15) {
                continue;
            }
            
            NSString *username = foodRecordData[1];
            NSString *productName = [[foodRecordData[0]
                                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                     stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
            NSDate *timestamp = [NSDate
                                 dateWithTimeIntervalSince1970:[foodRecordData[2]
                                                                doubleValue]];
            NSFetchRequest *request = [[NSFetchRequest alloc] init];
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(fullName == %@)", username];
            NSEntityDescription *description = [NSEntityDescription entityForName:@"User" inManagedObjectContext: self.managedObjectContext];
            [request setEntity:description];
            [request setPredicate:predicate];
            NSArray *localUsers = [self.managedObjectContext executeFetchRequest:request error:&e];
            
            if(localUsers == nil || localUsers.count == 0) {
                NSString *errorMsg = [NSString stringWithFormat:@"Cannot find user %@ food consumption record.", username];
                /*e = [NSError errorWithDomain:@"SychronizationService"
                 code: EntityNotFoundErrorCode
                 userInfo:@{NSLocalizedDescriptionKey:erroMsg}];
                 
                 CHECK_ERROR_AND_RETURN(e, error, errorMsg, EntityNotFoundErrorCode, YES, NO);*/
                e = nil;
                NSLog(@"Warning: %@", errorMsg);
                continue;
            }
            id<FoodProductService> foodProductService = [[FoodProductServiceImpl alloc] init];
            FoodProduct *product = [foodProductService getAllFoodProductByName:localUsers[0]
                                                                          name:productName error:&e];
            if (product == nil) {
                /*e = [NSError errorWithDomain:@"SychronizationService"
                                        code: EntityNotFoundErrorCode
                                    userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Cannot find food product for food consumption record."}];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot find food product for food consumption record.",
                                       EntityNotFoundErrorCode, YES, NO);*/
                e = nil;
                continue; // ignore
            }
            // Try to fetch existing FoodConsumptionRecord with the username, product name and
            // timestamp from Core Data managedObjectContext
            request = [[NSFetchRequest alloc] init];
            NSArray *timestamps = [NSArray arrayWithObjects:
                                   [timestamp dateByAddingTimeInterval:-0.5],
                                   [timestamp dateByAddingTimeInterval:0.5],
                                   nil
                                   ];
            if (foodRecordData.count <= 16) {
                predicate = [NSPredicate predicateWithFormat:@"(deleted == NO) AND (user.fullName == %@) "
                             "AND (foodProduct.name == %@) AND (timestamp >= %@) AND (timestamp <= %@)", username,
                             productName, timestamps[0], timestamps[1]];
            } else {
                NSString *savedObjectId = [[foodRecordData[16]
                                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                           stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
                predicate = [NSPredicate predicateWithFormat:@"(deleted == NO) AND (user.fullName == %@) "
                             "AND (foodProduct.name == %@) AND (savedObjectId == %@)", username, productName, savedObjectId];
            }
            description = [NSEntityDescription entityForName:@"FoodConsumptionRecord"
                                      inManagedObjectContext:[self managedObjectContext]];
            [request setEntity:description];
            [request setPredicate:predicate];
            NSArray *localRecords = [[self managedObjectContext] executeFetchRequest:request error:&e];
            id<FoodConsumptionRecordService> consumptionRecordService =
            [[FoodConsumptionRecordServiceImpl alloc] init];
            if ([localRecords count] > 0) {
                FoodConsumptionRecord *localRecord = localRecords[0];
                BOOL deleted = [foodRecordData[13] boolValue];
                if (deleted) {
                    [[self managedObjectContext] deleteObject:localRecord];
                } else {
                    // Extract other properties from foodConsumptionRecordData array, and update the
                    // FoodConsumptionRecord object
                    // refer to ADS 1.1.3 and data_sync_files/FoodConsumptionRecord.csv for detailed format
                    FoodConsumptionRecord *record =  [DataHelper
                                                      buildFoodConsumptionRecordFromData:foodRecordData
                                                      inManagedObjectContext:self.managedObjectContext
                                                      error:&e];
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot build FoodConsumptionRecord.",
                                           SynchronizationErrorCode, YES, NO);
                    [[self managedObjectContext] deleteObject:localRecord];
                    NSDate *createDate = record.createdDate;
                    NSDate *modifyDate = record.lastModifiedDate;
                    [consumptionRecordService addFoodConsumptionRecord:localUsers[0]
                                                                record:record error:&e];
                    record.foodProduct = product;
                    CHECK_ERROR_AND_RETURN(e, error, @"Cannot save FoodConsumptionRecord.",
                                           SynchronizationErrorCode, YES, NO);
                    record.lastModifiedDate = modifyDate;
                    record.createdDate = createDate;
                    record.synchronized = @YES;
                }
            } else {
                // Create a new FoodConsumptionRecord in Core Data managedObjectContext
                // Extract other properties from foodConsumptionRecordData array, and set the properties to
                // the new FoodConsumptionRecord object
                FoodConsumptionRecord *record =  [DataHelper
                                                  buildFoodConsumptionRecordFromData:foodRecordData
                                                  inManagedObjectContext:self.managedObjectContext
                                                  error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot build FoodConsumptionRecord.",
                                       SynchronizationErrorCode, YES, NO);
                NSDate *createDate = record.createdDate;
                NSDate *modifyDate = record.lastModifiedDate;
                [consumptionRecordService addFoodConsumptionRecord:localUsers[0] record:record error:&e];
                record.foodProduct = product;
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot save FoodConsumptionRecord.",
                                       SynchronizationErrorCode, YES, NO);
                record.lastModifiedDate = modifyDate;
                record.createdDate = createDate;
                record.synchronized = @YES;
            }
        }
        
        // Update progress
        currentProgress += (progressDelta / 3);
        [self updateProgress:[NSNumber numberWithFloat:currentProgress]];

        // Process SummaryGenerationHistory.csv
        data = [localClient readFile:[NSString stringWithFormat:@"data_sync/%@/data/SummaryGenerationHistory.csv",
                          subDirectory] error:&e];
        NSMutableArray *summaryGenerationHistoryDataArray = [parser parseData:data];
        for (NSMutableArray* summaryHistoryData in summaryGenerationHistoryDataArray) {
            NSString *username = summaryHistoryData[0];
            NSDate *startDate =[NSDate dateWithTimeIntervalSince1970:[summaryHistoryData[1]
                                                                      doubleValue]];
            NSDate *endDate =[NSDate dateWithTimeIntervalSince1970:[summaryHistoryData[2]
                                                                    doubleValue]];
            // Try to fetch existing SummaryGenerationHistory with the username, startDate and endDate
            // from Core Data managedObjectContext
            request = [[NSFetchRequest alloc] init];
            predicate = [NSPredicate predicateWithFormat:@"(deleted == NO) AND (user.fullName == %@) AND "
                         "(startDate == %@) AND (endDate == %@)", username, startDate, endDate];
            description = [NSEntityDescription entityForName:@"SummaryGenerationHistory"
                                      inManagedObjectContext:[self managedObjectContext]];
            [request setEntity:description];
            [request setPredicate:predicate];
            NSArray *localHistories = [[self managedObjectContext] executeFetchRequest:request error:&e];
            if ([localHistories count] > 0) {
                SummaryGenerationHistory *localHistory = localHistories[0];
                BOOL deleted = [summaryHistoryData[3] boolValue];
                if (deleted) {
                    [[self managedObjectContext] deleteObject:localHistory];
                } else {
                    // Extract other properties from summaryGenerationHistoryData array, and update the
                    // localHistory object
                    // refer to ADS 1.1.3 and data_sync_files/SummaryGenerationHistory.csv for format
                    localHistory.deleted = [summaryHistoryData[3] isEqualToString:@"YES"] ? @YES :@NO;
                    localHistory.lastModifiedDate = [NSDate
                                                     dateWithTimeIntervalSince1970:[summaryHistoryData[4]
                                                                                    doubleValue]];
                    localHistory.createdDate = [NSDate dateWithTimeIntervalSince1970:[summaryHistoryData[5]
                                                                                      doubleValue]];
                    localHistory.synchronized = @YES;
                }
            } else {
                request = [[NSFetchRequest alloc] init];
                predicate = [NSPredicate predicateWithFormat:@"(fullName == %@)", username];
                description = [NSEntityDescription entityForName:@"User" inManagedObjectContext:[self managedObjectContext]];
                [request setEntity:description];
                [request setPredicate:predicate];
                NSArray *localUsers = [[self managedObjectContext] executeFetchRequest:request error:&e];
                CHECK_ERROR_AND_RETURN(e, error, @"Cannot fetch user for summary generation history",
                                       EntityNotFoundErrorCode, YES, NO);
                if(localUsers == nil || localUsers.count == 0) {
                    NSString *errorMsg = [NSString stringWithFormat:@"Cannot find user %@ for summary generation history.", username];
                    /*e = [NSError errorWithDomain:@"SynchronizationService"
                                            code: EntityNotFoundErrorCode
                                        userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
                    CHECK_ERROR_AND_RETURN(e, error, errorMsg, EntityNotFoundErrorCode,YES, NO);*/
                    e = nil;
                    NSLog(@"Warning: %@", errorMsg);
                    continue;
                }
                
                // Create a new SummaryGenerationHistory in Core Data managedObjectContext
                SummaryGenerationHistory *history = [NSEntityDescription
                                                     insertNewObjectForEntityForName:@"SummaryGenerationHistory"
                                                     inManagedObjectContext:[self managedObjectContext]];
                history.user = localUsers[0];
                history.startDate = startDate;
                history.endDate = endDate;
                history.createdDate = [NSDate dateWithTimeIntervalSince1970:[summaryHistoryData[5]
                                                                             doubleValue]];
                history.lastModifiedDate = [NSDate
                                            dateWithTimeIntervalSince1970:[summaryHistoryData[4]
                                                                           doubleValue]];
                history.synchronized = @YES;
                history.deleted = @NO;
            }
        }
        
        // Update progress
        currentProgress += (progressDelta / 3);
        [self updateProgress:[NSNumber numberWithFloat:currentProgress]];
    }

    // Save changes in the managedObjectContext
    [[self managedObjectContext] save:&e];
    CHECK_ERROR_AND_RETURN(e, error, @"Cannot save managed object context.", SynchronizationErrorCode, YES, NO);
    
    // Unlock the managedObjectContext
    [[self managedObjectContext] unlock];
    
    // Update progress
    [self updateProgress:@1.0];
    
    [LoggingHelper logMethodExit:methodName returnValue:@YES];
    return YES;
}

#pragma mark - Sort method

NSComparisonResult sortByTimestamp(NSString *v1, NSString *v2, void *ignore) {
    return [v1 compare:v2];
}
@end