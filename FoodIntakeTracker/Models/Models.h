//
//  Models.h
//  ISSFoodIntakeTracker
//
//  Created by duxiaoyang on 2013-07-10.
//  Copyright (c) 2013 TopCoder. All rights reserved.
//

#ifndef ISSFoodIntakeTracker_Models_h
#define ISSFoodIntakeTracker_Models_h

#import "AdhocFoodProduct.h"
#import "FoodConsumptionRecord.h"
#import "FoodProduct.h"
#import "FoodProductFilter.h"
#import "StringWrapper.h"
#import "SynchronizableModel.h"
#import "User.h"
#import "SummaryGenerationHistory.h"

/*!
 @discussion Enumeration for food product sort options.
 @author flying2hk, duxiaoyang
 @version 1.0
 */
typedef enum {
    
    // Sort by consumption frequency from high to low
    FREQUENCY_HIGH_TO_LOW,
    
    // Sort by consumption frequency from low to high
    FREQUENCY_LOW_TO_HIGH,
    
    // Sort by name from A to Z
    A_TO_Z,
    
    // Sort by name from Z to A.
    Z_TO_A,
    
    // Sort by energy from high to low
    ENERGY_HIGH_TO_LOW,
    
    // Sort by energy from low to high
    ENERGY_LOW_TO_HIGH,
    
    // Sort by fluid from high to low
    FLUID_HIGH_TO_LOW,
    
    // Sort by fluid from low to high
    FLUID_LOW_TO_HIGH,
    
    // Sort by sodium from high to low
    SODIUM_HIGH_TO_LOW,
    
    // Sort by sodium from low to high
    SODIUM_LOW_TO_HIGH,

    // Sort by protein from high to low
    PROTEIN_HIGH_TO_LOW,
    
    // Sort by protein from low to high
    PROTEIN_LOW_TO_HIGH, 

    // Sort by carb from high to low
    CARB_HIGH_TO_LOW,
    
    // Sort by carb from low to high
    CARB_LOW_TO_HIGH,

    // Sort by fat from high to low
    FAT_HIGH_TO_LOW,
    
    // Sort by fat from low to high
    FAT_LOW_TO_HIGH,

} FoodProductSortOption;

/*!
 @discussion Enumeration for service error code.
 @author flying2hk, duxiaoyang
 @version 1.0
 */
typedef enum {

    // Indicate that the requested data entity can't be found
    EntityNotFoundErrorCode,
    
    // Indicate locking errors
    LockErrorCode,
    
    // Indicate that the food consumption record isn't modifiable
    FoodConsumptionRecordNotModifiableErrorCode,
    
    // Indicate that the WiFi network isn't available
    WiFiNotAvailableErrorCode,
    
    // Indicate errors during data synchronization
    SynchronizationErrorCode,
    
    // Indicate errors during data update
    DataUpdateErrorCode,
    
    // Indicate connection errors to shared file server
    ConnectionErrorCode,
    
    // Indicate invalid input arguments
    IllegalArgumentErrorCode,
    
    // File path not exists error
    FilePathNotExistErrorCode
    
} ServiceErrorCode;

#endif
