/*
  Copyright (C) 2004-2007 SKYRIX Software AG
  Copyright (C) 2007      Helge Hess
  Copyright (c) 2008-2022 Inverse inc.

  This file is part of SOGo.

  SOGo is free software; you can redistribute it and/or modify it under
  the terms of the GNU Lesser General Public License as published by the
  Free Software Foundation; either version 2, or (at your option) any
  later version.

  SOGo is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
  License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with SOGo; see the file COPYING.  If not, write to the
  Free Software Foundation, 59 Temple Place - Suite 330, Boston, MA
  02111-1307, USA.
*/

#import <NGExtensions/NSNull+misc.h>
#import <NGExtensions/NSObject+Logs.h>

#import <EOControl/EOFetchSpecification.h>
#import <EOControl/EOSortOrdering.h>
#import <EOControl/EOQualifier.h>

#import <GDLAccess/EOEntity.h>
#import <GDLAccess/EOAttribute.h>
#import <GDLAccess/EOSQLExpression.h>
#import <GDLAccess/EOSQLQualifier.h>
#import <GDLAccess/EOAdaptor.h>
#import <GDLAccess/EOAdaptorContext.h>

#import "GCSFieldInfo.h"
#import "GCSFolder.h"
#import "GCSFolderManager.h"
#import "GCSFolderType.h"
#import "GCSChannelManager.h"
#import "NSURL+GCS.h"
#import "EOAdaptorChannel+GCS.h"
#import "EOQualifier+GCS.h"
#import "GCSStringFormatter.h"

#if (defined(__GNU_LIBOBJC__) && (__GNU_LIBOBJC__ >= 20100911)) || defined(APPLE_RUNTIME) || defined(__GNUSTEP_RUNTIME__)
#  define sel_eq(__A__,__B__) sel_isEqual(__A__,__B__)
#endif

typedef enum {
  noTableRequired = 0,
  quickTableRequired = 1,
  contentTableRequired = 2,
  bothTableRequired = 3
} GCSTableRequirement;

@implementation GCSFolder

static BOOL debugOn    = NO;
static BOOL doLogStore = NO;

static Class NSStringClass       = Nil;
static Class NSNumberClass       = Nil;
static Class NSCalendarDateClass = Nil;

static GCSStringFormatter *stringFormatter = nil;

+ (void) initialize
{
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

  debugOn         = [ud boolForKey:@"GCSFolderDebugEnabled"];
  doLogStore      = [ud boolForKey:@"GCSFolderStoreDebugEnabled"];

  NSStringClass       = [NSString class];
  NSNumberClass       = [NSNumber class];
  NSCalendarDateClass = [NSCalendarDate class];

  stringFormatter = [GCSStringFormatter sharedFormatter];
}

- (id) initWithPath: (NSString *)_path
	 primaryKey: (id)_folderId
     folderTypeName: (NSString *)_ftname
	 folderType: (GCSFolderType *)_ftype
	   location: (NSURL *)_loc
      quickLocation: (NSURL *)_qloc
	aclLocation: (NSURL *)_aloc
      folderManager: (GCSFolderManager *)_fm
{
  NSEnumerator *fields;
  GCSFieldInfo *field;
  NSString *fieldName;

  if ((self = [super init])) {
    folderManager  = [_fm    retain];
    folderInfo     = [_ftype retain];
    fields = [[_ftype quickFields] objectEnumerator];
    quickFieldNames = [NSMutableArray new];
    while ((field = [fields nextObject]))
      {
	fieldName = [field columnName];

	if (![fieldName isEqualToString: @"c_name"])
	  [quickFieldNames addObject: fieldName];
      }

    fields = [[_ftype fields] objectEnumerator];
    contentFieldNames = [NSMutableArray new];
    while ((field = [fields nextObject]))
      {
	fieldName = [field columnName];

	if (![fieldName isEqualToString: @"c_name"])
          [contentFieldNames addObject: fieldName];
      }

    folderId       = [_folderId copy];
    folderName     = [[_path lastPathComponent] copy];
    path           = [_path   copy];
    location       = [_loc    retain];
    quickLocation  = _qloc ? [_qloc   retain] : [_loc retain];
    aclLocation    = [_aloc   retain];
    folderTypeName = [_ftname copy];

    ofFlags.requiresFolderSelect = 0;
    ofFlags.sameTableForQuick =
      [location isEqualTo:quickLocation] ? 1 : 0;
  }
  return self;
}

- (id) init
{
  return [self initWithPath:nil primaryKey:nil
	       folderTypeName:nil folderType:nil
	       location:nil quickLocation:nil
               aclLocation:nil
	       folderManager:nil];
}

- (id)initWithPath:(NSString *)_path
        primaryKey:(id)_folderId
    folderTypeName:(NSString *)_ftname
        folderType:(GCSFolderType *)_ftype
          location:(NSURL *)_loc
     quickLocation:(NSURL *)_qloc
     folderManager:(GCSFolderManager *)_fm
{
  return [self initWithPath:_path primaryKey:_folderId folderTypeName:_ftname
	       folderType:_ftype location:_loc quickLocation:_qloc
	       aclLocation:nil
	       folderManager:_fm];
}

- (void) dealloc
{
  [folderManager  release];
  [folderInfo     release];
  [folderId       release];
  [folderName     release];
  [path           release];
  [location       release];
  [quickLocation  release];
  [quickFieldNames release];
  [contentFieldNames release];
  [aclLocation    release];
  [folderTypeName release];
  [super dealloc];
}

/* accessors */

- (NSNumber *)folderId {
  return folderId;
}

- (NSString *)folderName {
  return folderName;
}
- (NSString *)path {
  return path;
}

- (NSURL *)location {
  if ([GCSFolderManager singleStoreMode])
    return [folderManager storeLocation];

  return location;
}
- (NSURL *)quickLocation {
  if ([GCSFolderManager singleStoreMode])
    {
      NSString *baseURL;
      NSRange range;

      baseURL = [[folderManager folderInfoLocation] absoluteString];
      range = [baseURL rangeOfString: @"/" options: NSBackwardsSearch];
      if (range.location != NSNotFound)
        baseURL = [baseURL substringToIndex: range.location];

      return [NSURL URLWithString: [NSString stringWithFormat: @"%@/%@", baseURL, [self quickTableName]]];
    }

  return quickLocation;
}
- (NSURL *)aclLocation {
  if ([GCSFolderManager singleStoreMode])
    return [folderManager aclLocation];

  return aclLocation;
}

- (NSString *)folderTypeName {
  return folderTypeName;
}

- (GCSChannelManager *)_channelManager {
  return [folderManager channelManager];
}

- (NSString *)storeTableName {
  return [[self location] gcsTableName];
}
- (NSString *)quickTableName {
  if ([GCSFolderManager singleStoreMode])
    return [NSString stringWithFormat: @"sogo_quick_%@", [folderTypeName lowercaseString]];

  return [[self quickLocation] gcsTableName];
}
- (NSString *)aclTableName {
  return [[self aclLocation] gcsTableName];
}

- (BOOL)isQuickInfoStoredInContentTable {
  return ofFlags.sameTableForQuick ? YES : NO;
}

/* channels */

- (EOAdaptorChannel *)acquireStoreChannel {
  return [[self _channelManager] acquireOpenChannelForURL:[self location]];
}
- (EOAdaptorChannel *)acquireQuickChannel {
  return [[self _channelManager] acquireOpenChannelForURL:[self quickLocation]];
}
- (EOAdaptorChannel *)acquireAclChannel {
  return [[self _channelManager] acquireOpenChannelForURL:[self aclLocation]];
}


- (void)releaseChannel:(EOAdaptorChannel *)_channel {
  [self releaseChannel: _channel  immediately: NO];
}

- (void) releaseChannel: (EOAdaptorChannel *) _channel
            immediately: (BOOL) _immediately
{
  if (debugOn) [self debugWithFormat:@"releasing channel: %@", _channel];
  [[self _channelManager] releaseChannel:_channel  immediately: _immediately];
}

- (BOOL)canConnectStore {
  return [[self _channelManager] canConnect:[self location]];
}
- (BOOL)canConnectQuick {
  return [[self _channelManager] canConnect:[self quickLocation]];
}
- (BOOL)canConnectAcl {
  return [[self _channelManager] canConnect:[self quickLocation]];
}

/* errors */

- (NSException *)errorVersionMismatchBetweenStoredVersion:(unsigned int)_store
  andExpectedVersion:(unsigned int)_base
{
  NSDictionary *ui;

  ui = [NSDictionary dictionaryWithObjectsAndKeys:
		       [NSNumber numberWithUnsignedInt:_base],
		       @"GCSExpectedVersion",
		       [NSNumber numberWithUnsignedInt:_store],
		       @"GCSStoredVersion",
  		       self, @"GCSFolder",
		       nil];

  return [NSException exceptionWithName:@"GCSVersionMismatch"
		      reason:@"Transaction conflict during a GCS modification."
		      userInfo:ui];
}

- (NSException *)errorExtractorReturnedNoQuickRow:(id)_extractor
  forContent:(NSString *)_content
{
  NSDictionary *ui;

  ui = [NSDictionary dictionaryWithObjectsAndKeys:
  		       self,       @"GCSFolder",
		       _extractor, @"GCSExtractor",
		       _content,   @"GCSContent",
		       nil];
  return [NSException exceptionWithName:@"GCSExtractFailed"
		      reason:@"Quickfield extractor did not return a result!"
		      userInfo:ui];
}

/* operations */

- (NSArray *)subFolderNames {
  return [folderManager listSubFoldersAtPath:[self path]
                                   recursive:NO];
}
- (NSArray *)allSubFolderNames {
  return [folderManager listSubFoldersAtPath:[self path]
                                   recursive:YES];
}

- (GCSTableRequirement) _tableRequirementForFields: (NSArray *) fields
				    andOrQualifier: (EOQualifier *) qualifier
{
  GCSTableRequirement requirement;
  NSMutableArray *allFields;
  NSArray *quFields;
  unsigned int fieldCount;

  requirement = noTableRequired;
  allFields = [NSMutableArray array];
  if ([fields count])
    [allFields addObjectsFromArray: fields];
  quFields = [[qualifier allQualifierKeys] allObjects];
  if ([quFields count])
    [allFields addObjectsFromArray: quFields];

  fieldCount = [allFields count];
  if (fieldCount)
    {
      if ([allFields firstObjectCommonWithArray: quickFieldNames])
	requirement |= quickTableRequired;
      if ([allFields firstObjectCommonWithArray: contentFieldNames])
	requirement |= contentTableRequired;
      if (requirement == noTableRequired
	  && [allFields containsObject: @"c_name"])
	requirement |= quickTableRequired;
    }
  else
    [NSException raise: @"GCSFolderMissingFieldNames"
                format: @"No field specified for query"];

  return requirement;
}

- (NSString *) _dottedFields: (NSArray *) fields
{
  NSMutableString *dottedFields;
  NSEnumerator *fieldsEnum;
  NSString *currentField, *prefix;

  dottedFields = [NSMutableString string];
  fieldsEnum = [fields objectEnumerator];
  while ((currentField = [fieldsEnum nextObject]))
    {
      if ([quickFieldNames containsObject: currentField])
	prefix = @"a";
      else
	prefix = @"b";
      [dottedFields appendFormat: @"%@.%@,", prefix, currentField];
    }
  [dottedFields deleteCharactersInRange: NSMakeRange ([dottedFields length] -
						      1, 1)];

  return dottedFields;
}

- (NSString *) _selectedFields: (NSArray *) fields
		   requirement: (GCSTableRequirement) requirement
{
  NSString *selectedFields;

  if (requirement == bothTableRequired && [fields containsObject: @"c_name"])
    selectedFields = [self _dottedFields: fields];
  else
    selectedFields = [fields componentsJoinedByString: @", "];

  return selectedFields;
}

- (NSString *) _sqlForQualifier: (EOQualifier *) qualifier
{
  static EOAdaptor *adaptor = nil;
  NSMutableString *ms;

  if (qualifier)
    {
      if (!adaptor)
        {
          EOAdaptorContext *adaptorCtx;
          EOAdaptorChannel *channel;
          channel = [self acquireStoreChannel];
          adaptorCtx = [channel adaptorContext];
          adaptor = [adaptorCtx adaptor];
        }

      ms = [NSMutableString stringWithCapacity:32];
      [qualifier appendSQLToString: ms
                       withAdaptor: adaptor];
    }
  else
    ms = nil;

  return ms;
}

- (NSString *)_sqlForSortOrderings:(NSArray *)_so {
  NSMutableString *sql;
  unsigned i, count;

  if ((count = [_so count]) == 0)
    return nil;

  sql = [NSMutableString stringWithCapacity:(count * 16)];
  for (i = 0; i < count; i++) {
    EOSortOrdering *so;
    NSString *column;
    SEL      sel;

    so     = [_so objectAtIndex:i];
    sel    = [so selector];
    column = [so key];

    if (i > 0) [sql appendString:@", "];

    if (sel_eq(sel, EOCompareAscending)) {
      [sql appendString:column];
      [sql appendString:@" ASC"];
    }
    else if (sel_eq(sel, EOCompareDescending)) {
      [sql appendString:column];
      [sql appendString:@" DESC"];
    }
    else if (sel_eq(sel, EOCompareCaseInsensitiveAscending)) {
      [sql appendString:@"UPPER("];
      [sql appendString:column];
      [sql appendString:@") ASC"];
    }
    else if (sel_eq(sel, EOCompareCaseInsensitiveDescending)) {
      [sql appendString:@"UPPER("];
      [sql appendString:column];
      [sql appendString:@") DESC"];
    }
    else {
      [self logWithFormat:@"cannot handle sort selector in store: %@",
	      NSStringFromSelector(sel)];
    }
  }
  return sql;
}

- (NSString *) _queryForFields: (NSArray *) fields
                          spec: (EOFetchSpecification *) spec
		 ignoreDeleted: (BOOL) ignoreDeleted
{
  EOQualifier      *qualifier;
  EOSortOrdering   *ordering;
  NSArray          *sortOrderings;
  NSEnumerator     *sortOrderingsList;
  NSMutableString  *sql;
  NSMutableArray   *allFields, *whereSql;
  GCSTableRequirement requirement;
  NSString *whereString;

  qualifier = [spec qualifier];
  sortOrderings = [spec sortOrderings];

  if (fields)
    allFields = [NSMutableArray arrayWithArray: fields];
  else
    allFields = [NSMutableArray arrayWithCapacity: [sortOrderings count]];

  if ([sortOrderings count] > 0)
    {
      sortOrderingsList = [sortOrderings objectEnumerator];
      while ((ordering = [sortOrderingsList nextObject]))
        {
          if (![allFields containsObject: [ordering key]])
            [allFields addObject: [ordering key]];
        }
    }
  requirement = [self _tableRequirementForFields: allFields
                                  andOrQualifier: qualifier];
  sql = [NSMutableString stringWithCapacity: 256];
  [sql appendString: @"SELECT "];
  if ([allFields count])
    [sql appendString: [self _selectedFields: allFields requirement: requirement]];
  else
    [sql appendString: @"*"];
  [sql appendString:@" FROM "];
  if (requirement == bothTableRequired)
    [sql appendFormat: @"%@ a, %@ b",
	 [self quickTableName], [self storeTableName]];
  else
    {
      if ((requirement & quickTableRequired))
	[sql appendString: [self quickTableName]];
      else if ((requirement & contentTableRequired))
	[sql appendString: [self storeTableName]];
    }

  whereSql = [NSMutableArray array];
  if ([GCSFolderManager singleStoreMode])
    {
      if (requirement == bothTableRequired)
        [whereSql addObject: [NSString stringWithFormat:
                                         @"(a.c_folder_id = %@ AND b.c_folder_id = %@)",
                                       folderId, folderId]];
      else
        [whereSql addObject: [NSString stringWithFormat: @"c_folder_id = %@",
                                       folderId]];
    }
  if (qualifier)
    {
      whereString = [NSString stringWithFormat: @"(%@)",
			      [self _sqlForQualifier: qualifier]];
      #warning this may be dangerous...
      if (requirement == bothTableRequired)
	[whereSql addObject: [whereString stringByReplacingString: @"c_name"
					  withString: @"a.c_name"]];
      else
	[whereSql addObject: whereString];
    }
  if (requirement == bothTableRequired)
    [whereSql addObject: @"a.c_name = b.c_name"];
  if ((requirement & contentTableRequired)
      && ignoreDeleted)
    [whereSql addObject: @"(c_deleted != 1 OR c_deleted IS NULL)"];
  if ([whereSql count])
    [sql appendFormat: @" WHERE %@",
	 [whereSql componentsJoinedByString: @" AND "]];

  if ([sortOrderings count] > 0)
    {
      [sql appendString:@" ORDER BY "];
      [sql appendString:[self _sqlForSortOrderings:sortOrderings]];
    }

#if 0
  /* limit */
  [sql appendString:@" LIMIT "]; // count
  [sql appendString:@" OFFSET "]; // index from 0
#endif

//   NSLog(@"/queryForFields...");

//   NSLog (@"query:\n/%@/", sql);

  return sql;
}

- (NSArray *) fetchFields: (NSArray *) fields
       fetchSpecification: (EOFetchSpecification *) spec
	    ignoreDeleted: (BOOL) ignoreDeleted
{
  EOAdaptorChannel *channel;
  NSException      *error;
  NSString  *sql;
  NSArray          *attrs;
  NSMutableArray   *results;
  NSDictionary     *row;

  sql = [self _queryForFields: fields spec: spec ignoreDeleted: ignoreDeleted];
  channel = [self acquireStoreChannel];
  if (channel)
    {
      /* run SQL */
//       NSLog(@"running query...");

      error = [channel evaluateExpressionX:sql];
      if (error)
	{
	  [self errorWithFormat:@"%s: cannot execute quick-fetch SQL '%@': %@",
		__PRETTY_FUNCTION__, sql, error];
	  results = nil;
	}
      else
	{
	  /* fetch results */

	  results = [NSMutableArray arrayWithCapacity: 64];
	  attrs = [channel describeResults: NO /* do not beautify names */];
	  while ((row = [channel fetchAttributes: attrs withZone: NULL]))
	    [results addObject: row];

	  /* release channels */

	}
      [self releaseChannel: channel];
//         NSLog(@"/running query");
    }
  else
    {
      [self errorWithFormat:@" could not open storage channel!"];
      results = nil;
    }

  return results;
}

- (EOFetchSpecification *) _simpleFetchSpecificationWith: (NSString *) field
						andValue: (NSString *) value
{
  EOQualifier *qualifier;

  qualifier
    = [EOQualifier qualifierWithQualifierFormat:
                     [NSString stringWithFormat: @"%@='%@'", field, value]];

  return [EOFetchSpecification
	   fetchSpecificationWithEntityName: [self folderName]
	   qualifier: qualifier
	   sortOrderings: nil];
}

- (NSDictionary *) recordOfEntryWithName: (NSString *) name
{
  NSDictionary *row;
  NSMutableDictionary *record;
  NSArray *rows, *columns;
  NSString *strValue;
  int intValue;

  columns = [NSArray arrayWithObjects: @"c_content", @"c_version",
		     @"c_creationdate", @"c_lastmodified", nil];
  rows
    = [self fetchFields: columns
	    fetchSpecification: [self _simpleFetchSpecificationWith: @"c_name"
				      andValue: name]
	    ignoreDeleted: YES];
  if ([rows count])
    {
      row = [rows objectAtIndex: 0];
      record = [NSMutableDictionary dictionaryWithCapacity: 5];
      strValue = [row objectForKey: @"c_content"];
      if (![strValue isNotNull])
	strValue = @"";
      [record setObject: strValue forKey: @"c_content"];
      [record setObject: [row objectForKey: @"c_version"]
	      forKey: @"c_version"];
      intValue = [[row objectForKey: @"c_creationdate"] intValue];
      [record
	setObject: [NSCalendarDate dateWithTimeIntervalSince1970: intValue]
	forKey: @"c_creationdate"];
      intValue = [[row objectForKey: @"c_lastmodified"] intValue];
      [record
	setObject: [NSCalendarDate dateWithTimeIntervalSince1970: intValue]
	forKey: @"c_lastmodified"];
    }
  else
    record = nil;

  return record;
}

/* writing content */

- (NSString *)_formatRowValue:(id)_value
withAdaptor: (EOAdaptor *)_adaptor
andAttribute: (EOAttribute *)_attribute
{
  if ([_value isKindOfClass:NSCalendarDateClass]) {
    _value = [NSString stringWithFormat: @"%d", (int)[_value timeIntervalSince1970]];
  }

  return [_adaptor formatValue: _value forAttribute: _attribute];
}

- (NSString *) _sqlTypeForColumn: (NSString *) _field withFieldInfos: (NSArray *) _fields
{
  NSString *sqlType;
  NSEnumerator *fields;
  GCSFieldInfo *fieldInfo;

  sqlType = nil;
  fields = [_fields objectEnumerator];
  while ((fieldInfo = [fields nextObject]))
    {
      if ([[fieldInfo columnName] caseInsensitiveCompare: _field] == NSOrderedSame)
        {
          sqlType = [fieldInfo sqlType];
          break;
        }
    }

  return sqlType;
}

- (EOAttribute *) _attributeForColumn: (NSString *) _field
{
  NSString *sqlType;
  EOAttribute *attribute;

  sqlType = [self _sqlTypeForColumn: _field
                  withFieldInfos: [folderInfo quickFields]];
  if (!sqlType)
    sqlType = [self _sqlTypeForColumn: _field
                    withFieldInfos: [folderInfo fields]];
  if (!sqlType && [_field isEqualToString: @"c_folder_id"])
    // The c_folder_id column used in single-store mode is not defined
    // in the OCS files; return the definition from the c_version column
    // which uses the same data type.
    sqlType = [self _sqlTypeForColumn: @"c_version"
                       withFieldInfos: [folderInfo fields]];
  if (sqlType)
    {
      attribute = AUTORELEASE([[EOAttribute alloc] init]);
      [attribute setName: _field];
      [attribute setColumnName: _field];
      [attribute setExternalType: sqlType];
    }
  else
    attribute = nil;

  return attribute;
}

- (NSString *) _generateInsertStatementForRow:(NSDictionary *)_row
                                      adaptor:(EOAdaptor *)_adaptor
                                      tableName:(NSString *)_table
{
  // TODO: move to NSDictionary category?
  NSMutableString *sql;
  NSString *fieldName;
  NSArray  *keys;
  EOAttribute *attribute;
  id value;
  unsigned i, count;

  if (_row == nil || _table == nil)
    return nil;

  keys = [_row allKeys];

  sql = [NSMutableString stringWithCapacity:512];
  [sql appendString:@"INSERT INTO "];
  [sql appendString:_table];
  [sql appendString:@" ("];

  for (i = 0, count = [keys count]; i < count; i++) {
    if (i != 0) [sql appendString:@", "];
    [sql appendString:[keys objectAtIndex:i]];
  }

  [sql appendString:@") VALUES ("];

  for (i = 0, count = [keys count]; i < count; i++) {
    fieldName = [keys objectAtIndex:i];
    attribute = [self _attributeForColumn: fieldName];
    if (attribute)
      {
        if (i != 0) [sql appendString:@", "];
        value = [self _formatRowValue: [_row objectForKey: fieldName]
                      withAdaptor: _adaptor andAttribute: attribute];
        [sql appendString: value];
      }
    else
      {
        [self errorWithFormat:@"%s: no type found for column name %@",
              __PRETTY_FUNCTION__, fieldName];
      }
  }

  [sql appendString:@")"];
  return sql;
}

- (NSString *)_generateUpdateStatementForRow:(NSDictionary *)_row
                                     adaptor:(EOAdaptor *)_adaptor
                                     tableName:(NSString *)_table
                                     whereColumn:(NSString *)_colname isEqualTo:(id)_value
                                     andColumn:(NSString *)_colname2  isEqualTo:(id)_value2
{
  // TODO: move to NSDictionary category?
  NSMutableString *sql;
  NSArray  *keys;
  NSString *fieldName;
  EOAttribute *attribute;
  id value;
  unsigned i, count;

  if (_row == nil || _table == nil)
    return nil;

  keys = [_row allKeys];

  sql = [NSMutableString stringWithCapacity:512];
  [sql appendString:@"UPDATE "];
  [sql appendString:_table];
  [sql appendString:@" SET "];

  for (i = 0, count = [keys count]; i < count; i++) {
    fieldName = [keys objectAtIndex:i];

    attribute = [self _attributeForColumn: fieldName];
    if (attribute)
      {
        if (i != 0) [sql appendString:@", "];
        [sql appendString:fieldName];
        [sql appendString:@" = "];
        value = [self _formatRowValue: [_row objectForKey: fieldName]
                      withAdaptor: _adaptor andAttribute: attribute];
        [sql appendString: value];
      }
    else
      {
        [self errorWithFormat:@"%s: no type found for column name %@",
              __PRETTY_FUNCTION__, fieldName];
      }
  }

  [sql appendString:@" WHERE "];
  if ([GCSFolderManager singleStoreMode])
    [sql appendString: [NSString stringWithFormat: @"c_folder_id = %@ AND ", folderId]];
  [sql appendString:_colname];
  [sql appendString:@" = "];
  attribute = [self _attributeForColumn: _colname];
  value = [self _formatRowValue: _value
                withAdaptor: _adaptor andAttribute: attribute];
  [sql appendString: value];

  if (_colname2 != nil) {
    [sql appendString:@" AND "];

    [sql appendString:_colname2];
    [sql appendString:@" = "];
    attribute = [self _attributeForColumn: _colname2];
    value = [self _formatRowValue: _value2
                withAdaptor: _adaptor andAttribute: attribute];
    [sql appendString: value];
  }

  return sql;
}

- (EOEntity *) _entityWithName: (NSString *) _name
{
  EOAttribute *attribute;
  EOEntity *entity;

  entity = AUTORELEASE([[EOEntity alloc] init]);
  [entity setName: _name];
  [entity setExternalName: _name];

  attribute = AUTORELEASE([[EOAttribute alloc] init]);
  [attribute setName: @"c_name"];
  [attribute setColumnName: @"c_name"];
  [entity addAttribute: attribute];

  return entity;
}

- (EOEntity *) _storeTableEntity
{
  EOAttribute *attribute;
  EOEntity *entity;

  entity = [self _entityWithName: [self storeTableName]];

  attribute = AUTORELEASE([[EOAttribute alloc] init]);
  [attribute setName: @"c_version"];
  [attribute setColumnName: @"c_version"];
  [entity addAttribute: attribute];

  return entity;
}

- (EOEntity *) _quickTableEntity
{
  EOEntity *entity;
  EOAttribute *attribute;
  NSEnumerator *fields;
  NSString *fieldName;

  entity = [self _entityWithName: [self quickTableName]];
  fields = [quickFieldNames objectEnumerator];
  while ((fieldName = [fields nextObject]))
    {
      attribute = AUTORELEASE([[EOAttribute alloc] init]);
      [attribute setName: fieldName];
      [attribute setColumnName: fieldName];
      [entity addAttribute: attribute];
    }

  return entity;
}

- (EOSQLQualifier *) _qualifierUsingWhereColumn:(NSString *)_colname
				      isEqualTo:(id)_value
				      andColumn:(NSString *)_colname2
				      isEqualTo:(id)_value2
					 entity: (EOEntity *)_entity
                                    withAdaptor: (EOAdaptor *)_adaptor
{
  EOSQLQualifier *qualifier;
  EOAttribute *attribute1, *attribute2;

  attribute1 = [self _attributeForColumn: _colname];
  if (_colname2 == nil)
    {
      if ([GCSFolderManager singleStoreMode])
        qualifier = [[EOSQLQualifier alloc] initWithEntity: _entity
                                           qualifierFormat: @"%A = %@ AND c_folder_id = %@", _colname,
                                     [self _formatRowValue:_value
                                               withAdaptor: _adaptor andAttribute: attribute1], folderId];
      else
        qualifier = [[EOSQLQualifier alloc] initWithEntity: _entity
                                           qualifierFormat: @"%A = %@", _colname,
                                     [self _formatRowValue:_value
                                               withAdaptor: _adaptor andAttribute: attribute1]];
    }
  else
    {
      attribute2 = [self _attributeForColumn: _colname2];
      if ([GCSFolderManager singleStoreMode])
        qualifier = [[EOSQLQualifier alloc] initWithEntity: _entity
                                           qualifierFormat: @"%A = %@ AND %A = %@ AND c_folder_id = %@",
                                            _colname,
                                     [self _formatRowValue:_value
                                               withAdaptor: _adaptor andAttribute: attribute1],
                                            _colname2,
                                     [self _formatRowValue:_value2
                                               withAdaptor: _adaptor andAttribute: attribute2]];
      else
        qualifier = [[EOSQLQualifier alloc] initWithEntity: _entity
                                           qualifierFormat: @"%A = %@ AND %A = %@",
                                            _colname,
                                     [self _formatRowValue:_value
                                               withAdaptor: _adaptor andAttribute: attribute1],
                                            _colname2,
                                     [self _formatRowValue:_value2
                                               withAdaptor: _adaptor andAttribute: attribute2],
                                            folderId];
    }

  return AUTORELEASE(qualifier);
}

- (void) _purgeRecordWithName: (NSString *) recordName
{
  NSString *delSql, *table;
  EOAdaptorContext *adaptorCtx;
  EOAdaptorChannel *channel;
  EOAttribute *attribute;

  channel = [self acquireStoreChannel];
  adaptorCtx = [channel adaptorContext];
  [adaptorCtx beginTransaction];

  table = [self storeTableName];
  attribute = [self _attributeForColumn: @"c_name"];
  if ([GCSFolderManager singleStoreMode])
    delSql = [NSString stringWithFormat: @"DELETE FROM %@"
                       @" WHERE c_name = %@ AND c_folder_id = %@", table,
                  [self _formatRowValue: recordName
                            withAdaptor: [adaptorCtx adaptor]
                           andAttribute: attribute], folderId];
  else
    delSql = [NSString stringWithFormat: @"DELETE FROM %@"
                       @" WHERE c_name = %@", table,
                  [self _formatRowValue: recordName
                            withAdaptor: [adaptorCtx adaptor]
                           andAttribute: attribute]];
  [channel evaluateExpressionX: delSql];

  [[channel adaptorContext] commitTransaction];
  [self releaseChannel: channel];
}

- (NSException *) writeContent: (NSString *) _content
                 fromComponent: (id) theComponent
                     container: (id) theContainer
  			toName: (NSString *) _name
		   baseVersion: (unsigned int *) _baseVersion
{
  EOAdaptorChannel    *storeChannel, *quickChannel;
  NSMutableDictionary *quickRow, *contentRow;
  NSDictionary	      *currentRow;
  NSNumber            *storedVersion;
  BOOL                isNewRecord, hasInsertDelegate, hasUpdateDelegate;
  NSCalendarDate      *nowDate, *startDate;
  NSNumber            *now;
  EOEntity *quickTableEntity, *storeTableEntity;
  NSArray *rows;
  NSException         *error;

  /* check preconditions */
  if (_name)
    {
      if (_content)
	{
	  /* run */
	  error   = nil;
	  nowDate = [NSCalendarDate date];
	  now     = [NSNumber numberWithUnsignedInt:[nowDate timeIntervalSince1970]];
    startDate = nil;

	  if (doLogStore)
	    [self logWithFormat:@"should store content: '%@'\n%@", _name, _content];

	  rows = [self fetchFields: [NSArray arrayWithObjects:
					       @"c_version",
					     @"c_deleted",
					     nil]
		       fetchSpecification: [self _simpleFetchSpecificationWith:
						   @"c_name"
						 andValue: _name]
		       ignoreDeleted: NO];
	  if ([rows count])
	    {
	      currentRow = [rows objectAtIndex: 0];
	      storedVersion = [currentRow objectForKey: @"c_version"];
	      if (doLogStore)
		[self logWithFormat:@"  version: %@", storedVersion];
	      if ([[currentRow objectForKey: @"c_deleted"] intValue] > 0)
		{
		  [self _purgeRecordWithName: _name];
		  isNewRecord = YES;
		}
	      else
		isNewRecord = NO;
	    }
	  else
	    {
	      storedVersion = nil;
	      isNewRecord = YES;
	    }

	  /* check whether sequence matches */
	  /* use version = 0 to override check */
	  if (*_baseVersion == 0
	      || *_baseVersion == [storedVersion unsignedIntValue])
	    {
	      /* extract quick info */
	      NSMethodSignature *aSignature;
	      NSInvocation *anInvocation;
	      SEL aSelector;

	      quickRow = nil;
	      aSelector = @selector(quickRecordFromContent:container:nameInContainer:);
	      aSignature = [[theComponent class] instanceMethodSignatureForSelector: aSelector];
	      anInvocation = [NSInvocation invocationWithMethodSignature:aSignature];
	      [anInvocation setSelector: aSelector];
	      [anInvocation setTarget: theComponent];
	      [anInvocation setArgument:&_content  atIndex: 2];
	      [anInvocation setArgument:&theContainer  atIndex: 3];
	      [anInvocation setArgument:&_name atIndex: 4];
	      [anInvocation invoke];
	      [anInvocation getReturnValue: &quickRow];

	      if (quickRow)
		{
		  [quickRow setObject:_name forKey:@"c_name"];

		  if (doLogStore)
		    [self logWithFormat:@"  store quick: %@", quickRow];

		  /* make content row */
		  contentRow = [NSMutableDictionary dictionaryWithCapacity:16];

		  if (ofFlags.sameTableForQuick)
		    [contentRow addEntriesFromDictionary:quickRow];

		  [contentRow setObject:_name forKey:@"c_name"];
		  [contentRow setObject:now forKey:@"c_lastmodified"];

		  if (isNewRecord)
		    {
		      [contentRow setObject:now forKey:@"c_creationdate"];
		      [contentRow setObject:[NSNumber numberWithInt:0]
				  forKey:@"c_version"];
		    }
		  else // TODO: increase version?
		    [contentRow setObject:
				  [NSNumber numberWithInt:([storedVersion intValue] + 1)]
				forKey:@"c_version"];
		  [contentRow setObject:_content forKey:@"c_content"];

		  /* open channels */
		  storeChannel = [self acquireStoreChannel];
		  if (storeChannel)
		    {
		      if (!ofFlags.sameTableForQuick)
			{
			  quickChannel = [self acquireQuickChannel];
			  if (!quickChannel)
			    {
			      [self errorWithFormat:@"%s: could not open quick channel!",
				    __PRETTY_FUNCTION__];
			      [self releaseChannel:storeChannel];
			      return nil;
			    }
			}
                      else
                        quickChannel = nil;

		      /* we check if we can call directly methods on our adaptor
			 channel delegate. If not, we generate SQL ourself since it'll
			 be a little bit faster and less complex than using GDL to do so */
		      hasInsertDelegate = [[storeChannel delegate]
					    respondsToSelector: @selector(adaptorChannel:willInsertRow:forEntity:)];
		      hasUpdateDelegate = [[storeChannel delegate]
					    respondsToSelector: @selector(adaptorChannel:willUpdateRow:describedByQualifier:)];

		      [[quickChannel adaptorContext] beginTransaction];
		      [[storeChannel adaptorContext] beginTransaction];

		      quickTableEntity = [self _quickTableEntity];
		      storeTableEntity = [self _storeTableEntity];

		      if (isNewRecord)
			{
                          if ([GCSFolderManager singleStoreMode])
                            {
                              [contentRow setObject: folderId  forKey:@"c_folder_id"];
                              [quickRow setObject: folderId  forKey:@"c_folder_id"];
                            }

			  if (!ofFlags.sameTableForQuick)
			    error = (hasInsertDelegate
				     ? [quickChannel insertRowX: quickRow forEntity: quickTableEntity]
				     : [quickChannel
					 evaluateExpressionX: [self _generateInsertStatementForRow: quickRow
                                                                    adaptor: [[quickChannel adaptorContext] adaptor]
								    tableName: [self quickTableName]]]);

			  if (!error)
			    error = (hasInsertDelegate
				     ? [storeChannel insertRowX: contentRow forEntity: storeTableEntity]
				     : [storeChannel
					 evaluateExpressionX: [self _generateInsertStatementForRow: contentRow
                                                                    adaptor: [[storeChannel adaptorContext] adaptor]
								    tableName: [self storeTableName]]]);
			}
		      else
			{
        // Update c_startdate for appointments
        if ([theComponent respondsToSelector:@selector(startDate)]) {
          NSTimeInterval t;
          startDate = [theComponent startDate];
          t = [startDate timeIntervalSince1970];
          if (startDate) {
            if (t < (long long)INT_MAX && t > (long long)INT_MIN)
              [quickRow setObject:[NSNumber numberWithInt: t] forKey:@"c_startdate"];
            else
              [quickRow setObject:[NSNumber numberWithInt: 0] forKey:@"c_startdate"];
          }
        }
      
			  if (!ofFlags.sameTableForQuick)
			    error = (hasUpdateDelegate
				     ? [quickChannel updateRowX: quickRow
						     describedByQualifier: [self _qualifierUsingWhereColumn: @"c_name"
										 isEqualTo: _name  andColumn: nil  isEqualTo: nil
										 entity: quickTableEntity
                                                                                 withAdaptor: [[storeChannel adaptorContext] adaptor]]]
				     : [quickChannel evaluateExpressionX: [self _generateUpdateStatementForRow: quickRow
                                                                                adaptor: [[quickChannel adaptorContext] adaptor]
										tableName: [self quickTableName]
										whereColumn: @"c_name" isEqualTo: _name
										andColumn: nil isEqualTo: nil]]);
			  if (!error)
			    error = (hasUpdateDelegate
				     ? [storeChannel updateRowX: contentRow
						     describedByQualifier: [self _qualifierUsingWhereColumn: @"c_name"  isEqualTo: _name
										 andColumn: (*_baseVersion != 0 ? (id)@"c_version" : (id)nil)
										 isEqualTo: (*_baseVersion != 0 ? [NSNumber numberWithUnsignedInt: *_baseVersion] : (NSNumber *)nil)
										 entity: storeTableEntity
                                                                                 withAdaptor: [[storeChannel adaptorContext] adaptor]]]
				     : [storeChannel evaluateExpressionX: [self _generateUpdateStatementForRow: contentRow
                                                                                adaptor: [[storeChannel adaptorContext] adaptor]
                                                                                tableName:[self storeTableName]
										whereColumn: @"c_name"  isEqualTo: _name
										andColumn: (*_baseVersion != 0 ? (id)@"c_version" : (id)nil)
										isEqualTo: (*_baseVersion != 0 ? [NSNumber numberWithUnsignedInt: *_baseVersion] : (NSNumber *)nil)]]);
		      }

		      if (error)
			{
			  [[storeChannel adaptorContext] rollbackTransaction];
			  [[quickChannel adaptorContext] rollbackTransaction];
			  [self logWithFormat:
				  @"ERROR(%s): cannot %s content : %@", __PRETTY_FUNCTION__,
				isNewRecord ? "insert" : "update",
				error];
			}
		      else
			{
			  if (!isNewRecord)
			    *_baseVersion += 1;

			  [[storeChannel adaptorContext] commitTransaction];
			  [[quickChannel adaptorContext] commitTransaction];
			}

		      [self releaseChannel: storeChannel];
		      if (!ofFlags.sameTableForQuick)
			[self releaseChannel: quickChannel];
		    }
		  else
		    [self errorWithFormat:@"%s: could not open storage channel!",
			  __PRETTY_FUNCTION__];
		}
	      else
                [self errorWithFormat:@"%s: could not extract quick row information",
                      __PRETTY_FUNCTION__];
	    }
	  else /* version mismatch (concurrent update) */
	    error = [self errorVersionMismatchBetweenStoredVersion:
			    [storedVersion unsignedIntValue]
			  andExpectedVersion: *_baseVersion];
  	}
      else
	error = [NSException exceptionWithName:@"GCSStoreException"
			     reason:@"no content was provided"
			     userInfo:nil];
    }
  else
    error = [NSException exceptionWithName:@"GCSStoreException"
			 reason:@"no content filename was provided"
			 userInfo:nil];

  return error;
}

- (NSException *) deleteContentWithName:(NSString *)_name {
  EOAdaptorChannel *storeChannel, *quickChannel;
  EOAdaptorContext *adaptorCtx;
  NSException *error;
  NSString *delsql;
  NSCalendarDate *nowDate;

  /* check preconditions */
  if (_name == nil) {
    return [NSException exceptionWithName:@"GCSDeleteException"
			reason:@"no content filename was provided"
			userInfo:nil];
  }

  if (doLogStore)
    [self logWithFormat:@"should delete content: '%@'", _name];

  /* open channels */

  if ((storeChannel = [self acquireStoreChannel]) == nil) {
    [self errorWithFormat:@"could not open storage channel!"];
    return nil;
  }
  if (ofFlags.sameTableForQuick)
    quickChannel = nil;
  else
    {
      quickChannel = [self acquireQuickChannel];
      if (!quickChannel)
	{
	  [self errorWithFormat:@"could not open quick channel!"];
	  [self releaseChannel:storeChannel];
	  return nil;
	}
    }

  if (!ofFlags.sameTableForQuick) [[quickChannel adaptorContext] beginTransaction];
  adaptorCtx = [storeChannel adaptorContext];
  [adaptorCtx beginTransaction];

  /* delete rows */
  nowDate = [NSCalendarDate calendarDate];

  delsql = [@"UPDATE " stringByAppendingString:[self storeTableName]];
  delsql = [delsql stringByAppendingString:@" SET c_deleted = 1"];
  delsql = [delsql stringByAppendingFormat:@", c_lastmodified = %u",
		   (unsigned int) [nowDate timeIntervalSince1970]];
  delsql = [delsql stringByAppendingString:@" WHERE c_name="];
  delsql = [delsql stringByAppendingString: [self _formatRowValue:_name
                                                  withAdaptor: [adaptorCtx adaptor]
                                                  andAttribute: [self _attributeForColumn: @"c_name"]]];
  if ([GCSFolderManager singleStoreMode])
    delsql = [delsql stringByAppendingFormat:@" AND c_folder_id = %@", folderId];
  if ((error = [storeChannel evaluateExpressionX:delsql]) != nil) {
    [self errorWithFormat:
	    @"%s: cannot delete content '%@': %@",
	  __PRETTY_FUNCTION__, delsql, error];
  }
  else if (!ofFlags.sameTableForQuick) {
    /* content row deleted, now delete the quick row */
    delsql = [@"DELETE FROM " stringByAppendingString:[self quickTableName]];
    delsql = [delsql stringByAppendingString:@" WHERE c_name="];
    delsql = [delsql stringByAppendingString: [self _formatRowValue:_name
                                                    withAdaptor: [adaptorCtx adaptor]
                                                    andAttribute: [self _attributeForColumn: @"c_name"]]];
    if ([GCSFolderManager singleStoreMode])
      delsql = [delsql stringByAppendingFormat:@" AND c_folder_id = %@", folderId];
    if ((error = [quickChannel evaluateExpressionX:delsql]) != nil) {
      [self errorWithFormat:
	      @"%s: cannot delete quick row '%@': %@",
	    __PRETTY_FUNCTION__, delsql, error];
      /*
	 Note: we now have a "broken" record, needs to be periodically GCed by
	       a script!
      */
    }
  }

  /* release channels and return */
  [adaptorCtx commitTransaction];
  [self releaseChannel:storeChannel];

  if (!ofFlags.sameTableForQuick) {
    [[quickChannel adaptorContext] commitTransaction];
    [self releaseChannel:quickChannel];
  }
  return error;
}

- (NSException *) deleteAllContent {
    NSException *error = nil;
    NSString *query;
    EOAdaptorChannel *storeChannel, *quickChannel;

    if ((storeChannel = [self acquireStoreChannel]) == nil) {
        [self errorWithFormat:@"could not open storage channel!"];
        return nil;
    }
    if (ofFlags.sameTableForQuick)
      quickChannel = nil;
    else
      {
        quickChannel = [self acquireQuickChannel];
        if (!quickChannel)
          {
            [self errorWithFormat:@"could not open quick channel!"];
            [self releaseChannel:storeChannel];
            return nil;
          }
    }

    if (!ofFlags.sameTableForQuick) [[quickChannel adaptorContext] beginTransaction];
    [[storeChannel adaptorContext] beginTransaction];

    if ([GCSFolderManager singleStoreMode])
      query = [NSString stringWithFormat: @"DELETE FROM %@ WHERE c_folder_id = %@", [self storeTableName], folderId];
    else
      query = [NSString stringWithFormat: @"DELETE FROM %@", [self storeTableName]];
    error = [storeChannel evaluateExpressionX:query];
    if (error)
      [self errorWithFormat: @"%s: cannot delete content '%@': %@",
        __PRETTY_FUNCTION__, query, error];
    else if (!ofFlags.sameTableForQuick) {
      /* content row deleted, now delete the quick row */
      if ([GCSFolderManager singleStoreMode])
        query = [NSString stringWithFormat: @"DELETE FROM %@ WHERE c_folder_id = %@", [self quickTableName], folderId];
      else
        query = [NSString stringWithFormat: @"DELETE FROM %@", [self quickTableName]];
      error = [quickChannel evaluateExpressionX: query];
      if (error)
        [self errorWithFormat: @"%s: cannot delete quick row '%@': %@",
              __PRETTY_FUNCTION__, query, error];
    }

    /* release channels and return */
    [[storeChannel adaptorContext] commitTransaction];
    [self releaseChannel:storeChannel];

    if (!ofFlags.sameTableForQuick) {
        [[quickChannel adaptorContext] commitTransaction];
        [self releaseChannel:quickChannel];
    }

    return error;
}

- (NSException *) purgeDeletedRecordsBefore: (unsigned int) days
{
  NSString *delSql, *table;
  EOAdaptorContext *adaptorCtx;
  EOAdaptorChannel *channel;
  NSCalendarDate *nowDate;
  unsigned int delta;

  channel = [self acquireStoreChannel];

  if ((channel = [self acquireStoreChannel]) == nil)
    return [NSException exceptionWithName: @"GCSChannelException"
                                   reason: @"could not open storage channel!"
                                 userInfo: nil];

  adaptorCtx = [channel adaptorContext];
  [adaptorCtx beginTransaction];

  table = [self storeTableName];
  nowDate = [NSCalendarDate date];
  delta = days * 24 * 60 * 60;
  if (delta > [nowDate timeIntervalSince1970])
    return [NSException exceptionWithName: @"GCSArgumentException"
                                   reason: @"number of days is too high!"
                                 userInfo: nil];
  delta = [nowDate timeIntervalSince1970] - delta;

  if ([GCSFolderManager singleStoreMode])
    delSql = [NSString stringWithFormat: @"DELETE FROM %@"
                       @" WHERE c_folder_id = %@ AND c_deleted = 1 AND c_lastmodified < %u",
                       table, folderId, delta];
  else
    delSql = [NSString stringWithFormat: @"DELETE FROM %@"
                       @" WHERE c_deleted = 1 AND c_lastmodified < %u",
                       table, delta];
  [channel evaluateExpressionX: delSql];

  [[channel adaptorContext] commitTransaction];
  [self releaseChannel: channel];

  return nil;
}

- (NSException *) touchContentWithName: (NSString *) _name
{
  NSString *touchSql, *table;
  EOAdaptorContext *adaptorCtx;
  EOAdaptorChannel *channel;
  EOAttribute *attribute;
  NSCalendarDate *nowDate;

  if (_name == nil)
      return [NSException exceptionWithName: @"GCSDeleteException"
				     reason: @"no content filename was provided"
				   userInfo: nil];

  channel = [self acquireStoreChannel];

  if ((channel = [self acquireStoreChannel]) == nil)
    {
      [self errorWithFormat:@"could not open storage channel!"];
      return nil;
    }

  adaptorCtx = [channel adaptorContext];
  [adaptorCtx beginTransaction];

  table = [self storeTableName];
  attribute = [self _attributeForColumn: @"c_name"];
  nowDate = [NSCalendarDate date];

  if ([GCSFolderManager singleStoreMode])
    touchSql = [NSString stringWithFormat: @"UPDATE %@ SET c_lastmodified = %u WHERE c_name = %@ AND c_folder_id = %@",
			 table,
			 (unsigned int) [nowDate timeIntervalSince1970],
		    [self _formatRowValue: _name
			      withAdaptor: [adaptorCtx adaptor]
			     andAttribute: attribute],
			 folderId];
  else
    touchSql = [NSString stringWithFormat: @"UPDATE %@ SET c_lastmodified = %u WHERE c_name = %@",
			 table,
			 (unsigned int) [nowDate timeIntervalSince1970],
		    [self _formatRowValue: _name
			      withAdaptor: [adaptorCtx adaptor]
			     andAttribute: attribute]];

  [channel evaluateExpressionX: touchSql];

  [[channel adaptorContext] commitTransaction];
  [self releaseChannel: channel];

  return nil;
}

- (NSException *)deleteFolder {
  EOAdaptorChannel *channel;
  NSString *delsql;
  NSString *table;

  /* open channels */

  if ((channel = [self acquireStoreChannel]) == nil) {
    [self errorWithFormat:@"could not open channel!"];
    return nil;
  }

  /* delete rows */
  [[channel adaptorContext] beginTransaction];
  table = [self storeTableName];
  if ([table length] > 0) {
    if ([GCSFolderManager singleStoreMode])
      delsql = [NSString stringWithFormat: @"DELETE FROM %@ WHERE c_folder_id = %@", table, folderId];
    else
      delsql = [@"DROP TABLE " stringByAppendingString: table];
    [channel evaluateExpressionX:delsql];
  }
  table = [self quickTableName];
  if ([table length] > 0) {
    if ([GCSFolderManager singleStoreMode])
      delsql = [NSString stringWithFormat: @"DELETE FROM %@ WHERE c_folder_id = %@", table, folderId];
    else
      delsql = [@"DROP TABLE " stringByAppendingString: table];
    [channel evaluateExpressionX:delsql];
  }
  table = [self aclTableName];
  if ([table length] > 0) {
    if ([GCSFolderManager singleStoreMode])
      delsql = [NSString stringWithFormat: @"DELETE FROM %@ WHERE c_folder_id = %@", table, folderId];
    else
      delsql = [@"DROP TABLE  " stringByAppendingString: table];
    [channel evaluateExpressionX:delsql];
  }

  [[channel adaptorContext] commitTransaction];
  [self releaseChannel:channel];

  return nil;
}

- (NSException *) updateQuickFields: (NSDictionary *) _fields
                        whereColumn: (NSString *) _colname
                          isEqualTo: (id) _value
{
  EOAdaptorChannel *quickChannel;
  EOAdaptorContext *adaptorCtx;
  NSException *error;

  quickChannel = [self acquireQuickChannel];
  adaptorCtx = [quickChannel adaptorContext];
  [adaptorCtx beginTransaction];
  error = [quickChannel updateRowX: _fields
              describedByQualifier: [self _qualifierUsingWhereColumn: _colname
                                          isEqualTo: _value andColumn: nil isEqualTo: nil
                                          entity: [self _quickTableEntity]
                                          withAdaptor: [adaptorCtx adaptor]]];

  if (error)
    {
      [adaptorCtx rollbackTransaction];
      [self logWithFormat:
              @"ERROR(%s): cannot update content : %@", __PRETTY_FUNCTION__, error];
    }
  else
    {
      [adaptorCtx commitTransaction];
    }

  [self releaseChannel: quickChannel];

  return error;
}

/* SQL generation */

/* fetching */
- (NSArray *) fetchFields: (NSArray *) fields
       fetchSpecification: (EOFetchSpecification *) spec
{
  return [self fetchFields: fields
	       fetchSpecification: spec
	       ignoreDeleted: YES];
}

- (NSArray *) fetchFields: (NSArray *) _flds
	matchingQualifier: (EOQualifier *)_q
{
  EOFetchSpecification *fs;

  if (_q == nil)
    fs = nil;
  else
    fs = [EOFetchSpecification fetchSpecificationWithEntityName:
				 [self folderName]
			       qualifier:_q
			       sortOrderings:nil];

  return [self fetchFields:_flds fetchSpecification:fs];
}

- (NSArray *) fetchAclWithSpecification: (EOFetchSpecification *)_fs
{
  EOQualifier      *qualifier;
  NSArray          *sortOrderings;
  EOAdaptorChannel *channel;
  NSException      *error;
  NSMutableString  *sql;
  NSArray          *attrs;
  NSMutableArray   *results;
  NSDictionary     *row;

  qualifier     = [_fs qualifier];
  sortOrderings = [_fs sortOrderings];

#if 0
  [self logWithFormat:@"FETCH: %@", _flds];
  [self logWithFormat:@"  MATCH: %@", _q];
#endif

  /* generate SQL */

  sql = [NSMutableString stringWithCapacity:256];
  [sql appendString:@"SELECT c_uid, c_object, c_role"];
  [sql appendString:@" FROM "];
  [sql appendString:[self aclTableName]];
  if ([GCSFolderManager singleStoreMode])
    [sql appendFormat:@" WHERE c_folder_id = %@", folderId];

  if (qualifier != nil) {
    if ([GCSFolderManager singleStoreMode])
      [sql appendFormat:@" AND (%@)", [self _sqlForQualifier:qualifier]];
    else
      {
        [sql appendString:@" WHERE "];
        [sql appendString:[self _sqlForQualifier:qualifier]];
      }
  }
  if ([sortOrderings count] > 0) {
    [sql appendString:@" ORDER BY "];
    [sql appendString:[self _sqlForSortOrderings:sortOrderings]];
  }
#if 0
  /* limit */
  [sql appendString:@" LIMIT "]; // count
  [sql appendString:@" OFFSET "]; // index from 0
#endif

  /* open channel */

  if ((channel = [self acquireAclChannel]) == nil) {
    [self errorWithFormat:@"could not open acl channel!"];
    return nil;
  }

  /* run SQL */

  if ((error = [channel evaluateExpressionX:sql]) != nil) {
    [self errorWithFormat:@"%s: cannot execute acl-fetch SQL '%@': %@",
	    __PRETTY_FUNCTION__, sql, error];
    [self releaseChannel:channel];
    return nil;
  }

  /* fetch results */

  results = [NSMutableArray arrayWithCapacity:64];
  attrs   = [channel describeResults:NO /* do not beautify names */];
  while ((row = [channel fetchAttributes:attrs withZone:NULL]) != nil)
    [results addObject:row];

  /* release channels */

  [self releaseChannel: channel];

  return results;
}

- (NSArray *) fetchAclMatchingQualifier: (EOQualifier *) _q
{
  EOFetchSpecification *fs;

  if (_q == nil)
    fs = nil;
  else {
    fs = [EOFetchSpecification fetchSpecificationWithEntityName:
				 [self folderName]
			       qualifier:_q
			       sortOrderings:nil];
  }
  return [self fetchAclWithSpecification:fs];
}

- (void) deleteAclMatchingQualifier: (EOQualifier *)_q
{
  EOFetchSpecification *fs;

  if (_q)
    {
      fs = [EOFetchSpecification fetchSpecificationWithEntityName:
				   [self folderName]
				 qualifier:_q
				 sortOrderings:nil];
      [self deleteAclWithSpecification: fs];
    }
}

- (void) deleteAclWithSpecification: (EOFetchSpecification *) _fs
{
  EOAdaptorChannel *channel;
  NSException      *error;
  NSMutableString  *sql;
  NSString *qSql;

  sql = [NSMutableString stringWithCapacity:256];
  [sql appendString:@"DELETE FROM "];
  [sql appendString:[self aclTableName]];
  if ([GCSFolderManager singleStoreMode])
    [sql appendFormat:@" WHERE c_folder_id = %@", folderId];
  qSql = [self _sqlForQualifier: [_fs qualifier]];
  if (qSql)
    {
      if ([GCSFolderManager singleStoreMode])
        [sql appendFormat:@" AND (%@)", qSql];
      else
        [sql appendFormat:@" WHERE %@", qSql];
    }

  /* open channel */
  if ((channel = [self acquireAclChannel]) == nil) {
    [self errorWithFormat:@"could not open acl channel!"];
    return;
  }

  /* run SQL */
  [[channel adaptorContext] beginTransaction];
  if ((error = [channel evaluateExpressionX:sql]) != nil) {
    [self errorWithFormat:@"%s: cannot execute acl-fetch SQL '%@': %@",
          __PRETTY_FUNCTION__, sql, error];
    [self releaseChannel:channel];
    return;
  }

  [[channel adaptorContext] commitTransaction];
  [self releaseChannel:channel];
}

- (unsigned int) recordsCountByExcludingDeleted: (BOOL) excludeDeleted
{
  NSMutableString  *sqlString;
  EOAdaptorChannel *channel;
  NSException *error;
  NSDictionary *row;
  unsigned int count;
  NSArray *attrs;

  count = 0;

  if ([GCSFolderManager singleStoreMode])
    sqlString = [NSMutableString stringWithFormat:
                                   @"SELECT COUNT(*) AS cnt FROM %@ WHERE c_folder_id = %@",
                                 [self storeTableName], folderId];
  else
    sqlString = [NSMutableString stringWithFormat:
                                   @"SELECT COUNT(*) AS cnt FROM %@",
                                 [self storeTableName]];
  if (excludeDeleted)
    {
      if ([GCSFolderManager singleStoreMode])
        [sqlString appendString: @" AND (c_deleted != 1 OR c_deleted IS NULL)"];
      else
        [sqlString appendString: @" WHERE (c_deleted != 1 OR c_deleted IS NULL)"];
    }

  channel = [self acquireStoreChannel];
  if (channel)
    {
      error = [channel evaluateExpressionX: sqlString];
      if (error)
	[self errorWithFormat: @"%s: cannot execute SQL '%@': %@",
	      __PRETTY_FUNCTION__, sqlString, error];
      else
	{
	  attrs = [channel describeResults: NO];
	  row = [channel fetchAttributes: attrs withZone: NULL];
	  count = [[row objectForKey: @"cnt"] unsignedIntValue];
	  [channel cancelFetch];
	}
      [self releaseChannel: channel];
    }

  return count;
}

- (unsigned int) recordsCountDeletedBefore: (unsigned int) days
{
  EOAdaptorChannel *channel;
  NSArray *attrs;
  NSCalendarDate *nowDate;
  NSDictionary *row;
  NSException *error;
  NSMutableString  *sqlString;
  unsigned int delta, count;

  count = 0;
  nowDate = [NSCalendarDate date];
  delta = days * 24 * 60 * 60;
  if (delta < [nowDate timeIntervalSince1970])
    delta = [nowDate timeIntervalSince1970] - delta;
  else
    delta = 0;

  if ([GCSFolderManager singleStoreMode])
    sqlString = [NSMutableString stringWithFormat:
                                   @"SELECT COUNT(*) AS cnt FROM %@"
                                 @" WHERE c_folder_id = %@ AND c_lastmodified < %u AND c_deleted = 1",
                                 [self storeTableName], folderId, delta];
  else
    sqlString = [NSMutableString stringWithFormat:
                                   @"SELECT COUNT(*) AS cnt FROM %@"
                                 @" WHERE c_lastmodified < %u AND c_deleted = 1",
                                 [self storeTableName], delta];

  channel = [self acquireStoreChannel];
  if (channel)
    {
      error = [channel evaluateExpressionX: sqlString];
      if (error)
	[self errorWithFormat: @"%s: cannot execute SQL '%@': %@",
	      __PRETTY_FUNCTION__, sqlString, error];
      else
	{
	  attrs = [channel describeResults: NO];
	  row = [channel fetchAttributes: attrs withZone: NULL];
	  count = [[row objectForKey: @"cnt"] unsignedIntValue];
	  [channel cancelFetch];
	}
      [self releaseChannel: channel];
    }

  return count;
}

- (NSCalendarDate *) lastModificationDate
{
  NSArray *records;
  EOFetchSpecification *lmSpec;
  EOSortOrdering *ordering;
  NSNumber *lastModified;
  NSCalendarDate *lastModificationDate = nil;

  ordering = [EOSortOrdering sortOrderingWithKey: @"c_lastmodified"
                                        selector: EOCompareDescending];
  lmSpec = [EOFetchSpecification
                   fetchSpecificationWithEntityName: [self folderName]
                                          qualifier: nil
                                      sortOrderings: [NSArray arrayWithObject: ordering]];

  records = [self        fetchFields: [NSArray arrayWithObject: @"c_lastmodified"]
                  fetchSpecification: lmSpec
                       ignoreDeleted: NO];
  if ([records count])
    {
      lastModified
        = [[records objectAtIndex: 0] objectForKey: @"c_lastmodified"];
      lastModificationDate
        = [NSCalendarDate dateWithTimeIntervalSince1970:
                            (NSTimeInterval) [lastModified intValue]];
    }

  return lastModificationDate;
}

/* description */

- (NSString *)description {
  NSMutableString *ms;
  id tmp;

  ms = [NSMutableString stringWithCapacity:256];
  [ms appendFormat:@"<0x%p[%@]:", self, NSStringFromClass([self class])];

  if (folderId)
    [ms appendFormat:@" id=%@", folderId];
  else
    [ms appendString:@" no-id"];

  if ((tmp = [self path]))           [ms appendFormat:@" path=%@", tmp];
  if ((tmp = [self folderTypeName])) [ms appendFormat:@" type=%@", tmp];
  if ((tmp = [self location]))
    [ms appendFormat:@" loc=%@", [tmp absoluteString]];

  [ms appendString:@">"];
  return ms;
}

@end /* GCSFolder */
