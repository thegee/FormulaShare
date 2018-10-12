public with sharing class FormulaShareService {

	public static Integer batchSize = 200;

	public class FormulaShareException extends Exception{}

	public static void triggerHandler() {

		// Process inserts and updates only (delete and undelete of shared object won't need changes)
		if(Trigger.isAfter && (Trigger.isInsert || Trigger.isUpdate)) {

			// Get SObject type
			List<sObject> recordsChanged = Trigger.new;
			sObjectType type = recordsChanged[0].getSObjectType();

			handleShareChanges(type, Trigger.oldMap, Trigger.newMap);
		}
	}


	public static void handleShareChanges(Schema.SObjectType type, Map<Id, SObject> existingRecords, Map<Id, SObject> newRecords) {

		ProcessFormulaShareQueueable job;
		FormulaShareWrapper fsWrapper = new FormulaShareWrapper(type);

		Boolean isUpdate = existingRecords != null ? true : false;

		// If insert, submit all records
		if(!isUpdate) {
			fsWrapper.recordsMap = newRecords;

			// Queue job for processing relevant records
			job = new ProcessFormulaShareQueueable(fsWrapper);
			ID formulaShareInsertJobID = System.enqueueJob(job);
		}

		// If update, submit those where one or more share to formula field has changed
		else {
			Map<Id,SObject> recordsWithSharingChanges = new Map<Id,SObject>();

			for(SObject newRecord : newRecords.values()) {
				SObject oldRecord = existingRecords.get((Id) newRecord.get('Id'));
				
				for(FormulaShare_Rule__mdt rule : fsWrapper.typeRules.rules) {
					String sharedTo = rule.Shared_To_Id_Field__c;

					if(oldRecord.get(sharedTo) != newRecord.get(sharedTo)) {
						recordsWithSharingChanges.put((Id) newRecord.get('Id'), newRecord);
					}
				}
			}

			if(!recordsWithSharingChanges.isEmpty()) {
				fsWrapper.recordsMap = recordsWithSharingChanges;

				// Queue job for processing relevant records
				job = new ProcessFormulaShareQueueable(fsWrapper);
				ID formulaShareUpdateJobID = System.enqueueJob(job);
			}
		}

	}


	// Core method to be called from various contexts
	public static void processFormulaShares(FormulaShareWrapper fsWrapper) {

		// Retrieve current record shares if type in scope is a custom object
		if(fsWrapper.typeRules.type.getDescribe().isCustom()) {
			
			// Get all relevant row causes (aka apex sharing reasons) used in rules
			Set<String> rowCauseSet = new Set<String>();
			for(FormulaShare_Rule__mdt rule : fsWrapper.typeRules.rules) {
				rowCauseSet.add(rule.Sharing_Reason__c);
			}

			String sharesQueryStringCustom = buildShareQueryCustom(fsWrapper, rowCauseSet);
			List<SObject> sharesQueryResultCustom = Database.query(sharesQueryStringCustom);
			system.debug('Share query result: '+sharesQueryResultCustom);

			// Create map of shareQueryResults with record shares unique key
			for(SObject share : sharesQueryResultCustom) {
				String shareKey = FormulaShareUtilities.getShareRecordKeyCustom(share);
				fsWrapper.mapToDelete.put(shareKey, share);
			}
		}

		// Retrieve current record shares if type in scope is a standard object
		else {
			String sharesQueryStringStandard = buildShareQueryStandard(fsWrapper);
			List<SObject> sharesQueryResultStandard = Database.query(sharesQueryStringStandard);
			system.debug('Share query result: '+sharesQueryResultStandard);

			// Create map of shareQueryResults with record shares unique key
			for(SObject share : sharesQueryResultStandard) {
				String shareKey = FormulaShareUtilities.getShareRecordKeyStandard(fsWrapper.typeRules.type, share);
				fsWrapper.mapToDelete.put(shareKey, share);
			}
		}

		// Assess sharing to be created or kept (will update deletion and insertion maps)
		assessRequiredShares(fsWrapper);

		// Remove sharing which is no longer needed
		System.debug('Sharing to be removed: '+fsWrapper.mapToDelete.values());
		delete fsWrapper.mapToDelete.values();

		// Insert new object share records
		System.debug('Sharing to be inserted: '+fsWrapper.setToInsert);
		List<SObject> sharesToInsertList = new List<SObject>(fsWrapper.setToInsert);
		insert sharesToInsertList;
	}


	public static void assessRequiredShares(FormulaShareWrapper fsWrapper) {
		
		Set<Id> roleQueryIdSet = new Set<Id>();
		Set<Id> roleSubordinatesQueryIdSet = new Set<Id>();
		Set<SObjectRule> roleRecordRules = new Set<SObjectRule>();
		Set<SObjectRule> roleSubordinateRecordRules = new Set<SObjectRule>();

		for(SObject record : fsWrapper.recordsMap.values()) {
			
			for(FormulaShare_Rule__mdt rule : fsWrapper.typeRules.rules) {
			String sharedToString = (String) record.get(rule.Shared_To_Id_Field__c);
				
				// Only need to check records where sharing field is populated
				if(!String.isBlank(sharedToString)) {
					try {

						// Add User Id to map
						if(rule.Share_With__c == 'Users') {
							if(FormulaShareUtilities.isValidIdType(sharedToString, Schema.User.getSObjectType())) {
								updateShareMaps(record.Id, (Id) sharedToString, rule, fsWrapper);
							}
							else {
								throw new FormulaShareException();
							}
						}

						// Add Group Id to map
						else if(rule.Share_With__c == 'Public Groups') {
							if(FormulaShareUtilities.isValidIdType(sharedToString, Schema.Group.getSObjectType())) {
								updateShareMaps(record.Id, (Id) sharedToString, rule, fsWrapper);
							}
							else {
								throw new FormulaShareException();
							}
						}

						// Add Role Id to role group query set
						else if(rule.Share_With__c == 'Roles') {
							if(FormulaShareUtilities.isValidIdType(sharedToString, Schema.UserRole.getSObjectType())) {
								roleQueryIdSet.add((Id) sharedToString);
								SObjectRule recordRule = new SObjectRule();
								recordRule.obj = record;
								recordRule.rule = rule;
								roleRecordRules.add(recordRule);
							}
							else {
								throw new FormulaShareException();
							}
						}

						// Add Role Id to role and subordinates group query set
						else if(rule.Share_With__c == 'Roles and Internal Subordinates') {
							if(FormulaShareUtilities.isValidIdType(sharedToString, Schema.UserRole.getSObjectType())) {
								roleSubordinatesQueryIdSet.add((Id) sharedToString);
								SObjectRule recordRule = new SObjectRule();
								recordRule.obj = record;
								recordRule.rule = rule;
								roleSubordinateRecordRules.add(recordRule);
							}
							else {
								throw new FormulaShareException();
							}
						}
					}
					catch(FormulaShareException e) {
						system.debug('Expected Id of type ' + rule.Share_With__c
						+ ' in field ' + rule.Shared_To_Id_Field__c
						+ ' on object ' + rule.Shared_Object__c
						+ '. For record ' + record.Id
						+ ' instead found value ' + sharedToString);
					}
				}
			}
		}

		// Query for all role and/or role and subordinate records
		if(!roleQueryIdSet.isEmpty() || !roleSubordinatesQueryIdSet.isEmpty()) {
			assessRoleSharing(roleQueryIdSet, roleRecordRules, roleSubordinatesQueryIdSet, roleSubordinateRecordRules, fsWrapper);
		}
	}


	public static void assessRoleSharing(Set<Id> roleQueryIdSet, Set<SObjectRule> roleRecordRules
		, Set<Id> roleSubordinatesQueryIdSet, Set<SObjectRule> roleSubordinateRecordRules
		, FormulaShareWrapper fsWrapper) {

		// Split out rules sharing to roles and roles and subordinates
		List<FormulaShare_Rule__mdt> roleRules = new List<FormulaShare_Rule__mdt>();
		List<FormulaShare_Rule__mdt> roleSubordinateRules = new List<FormulaShare_Rule__mdt>();
		for(FormulaShare_Rule__mdt rule : fsWrapper.typeRules.rules) {
			if(rule.Share_With__c == 'Roles') {
				roleRules.add(rule);
			}
			else if(rule.Share_With__c == 'Roles and Internal Subordinates') {
				roleSubordinateRules.add(rule);
			}
		}

		// Build map of required group Ids for role groups
		Map<String,Id> roleGroupIds = new Map<String,Id>();
		for(Group grp : [SELECT Id, RelatedId, Type 
			FROM Group 
			WHERE (RelatedId IN :roleQueryIdSet AND Type = 'Role')
			OR (RelatedId IN :roleSubordinatesQueryIdSet AND Type = 'RoleAndSubordinates')]) {

			String shortRelatedToId = FormulaShareUtilities.get15CharacterId(grp.RelatedId);
			String key = shortRelatedToId + grp.Type;
			roleGroupIds.put(key, grp.Id);
		}

		// Update sharing maps to create or keep role shares
		for(SObjectRule recordRule : roleRecordRules) {
			Id sharedToId = (Id) recordRule.obj.get(recordRule.rule.Shared_To_Id_Field__c);
			String shortSharedToId = FormulaShareUtilities.get15CharacterId(sharedToId);
			Id roleGroupId = roleGroupIds.get(shortSharedToId + 'Role');
			updateShareMaps(recordRule.obj.Id, roleGroupId, recordRule.rule, fsWrapper);
		}

		// Update sharing maps to create or keep role and subordinate shares
		for(SObjectRule recordRule : roleSubordinateRecordRules) {
			Id sharedToId = (Id) recordRule.obj.get(recordRule.rule.Shared_To_Id_Field__c);
			String shortSharedToId = FormulaShareUtilities.get15CharacterId(sharedToId);
			Id roleGroupId = roleGroupIds.get(shortSharedToId + 'RoleAndSubordinates');
			updateShareMaps(recordRule.obj.Id, roleGroupId, recordRule.rule, fsWrapper);
		}
	}


	public static void updateShareMaps(Id recordId, Id sharedTo, FormulaShare_Rule__mdt rule, FormulaShareWrapper fsWrapper) {
		
		// For custom objects, check whether sharing record for this sharing reason exists at correct access level
		if(fsWrapper.typeRules.type.getDescribe().isCustom()) {
			updateShareMapsCustom(recordId, sharedTo, rule, fsWrapper);
		}

		// For standard objects, check whether any sharing record exists at this access level or higher
		else {
			updateShareMapsStandard(recordId, sharedTo, rule, fsWrapper);
		}
	}


	public static void updateShareMapsCustom(Id recordId, Id sharedTo, FormulaShare_Rule__mdt rule, FormulaShareWrapper fsWrapper) {
		String shareKey = FormulaShareUtilities.get15CharacterId(recordId)
			 + FormulaShareUtilities.get15CharacterId(sharedTo) 
			 + rule.Access_Level__c
			 + rule.Sharing_Reason__c;
		
		// If share record exists already, remove from map to be deleted
		if(fsWrapper.mapToDelete.get(shareKey) != null) {
			fsWrapper.mapToDelete.remove(shareKey);
		}

		// Otherwise add to map to be inserted
		else {
			SObject newShare = getShareRecordCustom(fsWrapper.typeRules.type, recordId, sharedTo, rule);
			fsWrapper.setToInsert.add(newShare);
		}
	}


	public static void updateShareMapsStandard(Id recordId, Id sharedTo, FormulaShare_Rule__mdt rule, FormulaShareWrapper fsWrapper) {

		// Check whether we have any shares for this record already
		String shareKeyBase = FormulaShareUtilities.get15CharacterId(recordId) + FormulaShareUtilities.get15CharacterId(sharedTo);
		String shareKeyAll = shareKeyBase + 'All';
		String shareKeyEdit = shareKeyBase + 'Edit';
		String shareKeyRead = shareKeyBase + 'Read';

		system.debug('*** searching with this Id: ' + shareKeyEdit);
		system.debug('*** full map keys: ' + fsWrapper.mapToDelete.keySet() );
		system.debug('result of EDIT search: ' + fsWrapper.mapToDelete.get(shareKeyEdit));

		// If we already have a record with All, keep this
		if(fsWrapper.mapToDelete.get(shareKeyAll) != null) {
			fsWrapper.mapToDelete.remove(shareKeyAll);
		}

		// If we have a record with Edit...
		else if(fsWrapper.mapToDelete.get(shareKeyEdit) != null) {

			// If intended access level is Edit or lower, keep this record
			if(rule.Access_Level__c == 'Edit' || rule.Access_Level__c == 'Read') {
				fsWrapper.mapToDelete.remove(shareKeyEdit);
			}

			// Otherwise add higher level share to be inserted
			else {
				SObject newShare = getShareRecordStandard(fsWrapper.typeRules.type, recordId, sharedTo, rule);
				fsWrapper.setToInsert.add(newShare);
			}
		}

		// If we have a record with Read...
		else if(fsWrapper.mapToDelete.get(shareKeyRead) != null) {

			// If intended access level is Read, keep this record
			if(rule.Access_Level__c == 'Read') {
				fsWrapper.mapToDelete.remove(shareKeyEdit);
			}

			// Otherwise add higher level share to be inserted
			else {
				SObject newShare = getShareRecordStandard(fsWrapper.typeRules.type, recordId, sharedTo, rule);
				fsWrapper.setToInsert.add(newShare);
			}
		}

		// If no share found, add to be created
		else {
				SObject newShare = getShareRecordStandard(fsWrapper.typeRules.type, recordId, sharedTo, rule);
				fsWrapper.setToInsert.add(newShare);
		}
	}


	public static String buildShareQueryCustom(FormulaShareWrapper fsWrapper, Set<String> rowCauseSet) {
		SObjectType shareObjectType = FormulaShareUtilities.getShareObject(fsWrapper.typeRules.type);
		String parentIdsString = FormulaShareUtilities.buildStringFromSetQuotes(fsWrapper.recordsMap.keySet());
		String rowCausesString = FormulaShareUtilities.buildStringFromSetQuotes(rowCauseSet);
		String queryString = 'SELECT Id, UserOrGroupId, ParentId, AccessLevel'
			+' FROM '+shareObjectType
			+' WHERE ParentId IN (' + parentIdsString + ') AND RowCause IN (' + rowCausesString + ')';
		system.debug('Share query: ' + queryString);
		return queryString;
	}


	public static String buildShareQueryStandard(FormulaShareWrapper fsWrapper) {
		String objectName = fsWrapper.typeRules.type.getDescribe().getName();
		SObjectType shareObjectType = FormulaShareUtilities.getShareObject(fsWrapper.typeRules.type);
		String parentIdsString = FormulaShareUtilities.buildStringFromSetQuotes(fsWrapper.recordsMap.keySet());
		String queryString = 'SELECT Id, UserOrGroupId, ' + objectName + 'Id, ' + objectName + 'AccessLevel'
			+' FROM ' + shareObjectType
			+' WHERE ' + objectName + 'Id IN (' + parentIdsString + ') AND RowCause = \'Manual\'';
		return queryString;
	}


	public static SObject getShareRecordCustom(Schema.SObjectType type, Id recordId, Id sharedTo, FormulaShare_Rule__mdt rule) {
		Schema.SObjectType shareType = FormulaShareUtilities.getShareObject(type);
		SObject newShare = shareType.newSObject();
		newShare.put('AccessLevel',rule.Access_Level__c);
		newShare.put('ParentId',recordId);
		newShare.put('RowCause',rule.Sharing_Reason__c);
		newShare.put('UserOrGroupId',sharedTo);
		return newShare;
	}


	public static SObject getShareRecordStandard(Schema.SObjectType type, Id recordId, Id sharedTo, FormulaShare_Rule__mdt rule) {
		Schema.SObjectType shareType = FormulaShareUtilities.getShareObject(type);
		SObject newShare = shareType.newSObject();
		newShare.put(type + 'AccessLevel',rule.Access_Level__c);
		newShare.put(type + 'Id',recordId);
		newShare.put('RowCause','Manual');		// Only reason supported for standard objects
		newShare.put('UserOrGroupId',sharedTo);
		return newShare;
	}


	// Used by batch job
	public static String getFullObjectQuery(RulesForTypeWrapper typeRules) {
		String objectName = typeRules.type.getDescribe().getName();
		Set<String> sharedToFieldSet = new Set<String>();
		for(FormulaShare_Rule__mdt rule : typeRules.rules) {
			String sharedTo = rule.Shared_To_Id_Field__c;
			sharedToFieldSet.add(sharedTo);
		}
		String query = 'SELECT Id, ' + FormulaShareUtilities.buildStringFromSetNoQuotes(sharedToFieldSet)
			+ ' FROM ' + objectName;
		System.debug('Full object query: ' + query);
		return query;
	}


	public class FormulaShareWrapper {
		public RulesForTypeWrapper typeRules;
		public Map<Id,SObject> recordsMap = new Map<Id,SObject>();
		public Map<String,SObject> mapToDelete = new Map<String,SObject>();
		public Set<SObject> setToInsert = new Set<SObject>();

		// Set typeRules if provided
		public FormulaShareWrapper(RulesForTypeWrapper typeRules) {
			this.typeRules = typeRules;
		}

		// Or call RulesForTypeWrapper constructor if only type provided
		public FormulaShareWrapper(Schema.SObjectType type) {
			RulesForTypeWrapper newTypeRules = new RulesForTypeWrapper(type);
			this.typeRules = newTypeRules;
		}

	}


	public class RulesForTypeWrapper {
		public Schema.SObjectType type;
		public List<FormulaShare_Rule__mdt> rules;

		// Set type and find relevant rules on creation
		public RulesForTypeWrapper(Schema.SObjectType type) {
			this.type = type;
			this.rules = getRulesSharingObject(type);
			system.debug('fsWrapper rules populated: '+rules);
		}	
	}


	private class SObjectRule {
		SObject obj;
		FormulaShare_Rule__mdt rule;
	}


	public static List<FormulaShare_Rule__mdt> getRulesSharingObject(Schema.sObjectType type) {

		String objectName = type.getDescribe().getName();

		// Create list of all jobs with relevant details for assessing scope
		List<FormulaShare_Rule__mdt> rulesSharingObject =
			[SELECT Id, Access_Level__c, Shared_Object__c, Shared_To_Id_Field__c, Share_With__c, Sharing_Reason__c
			FROM FormulaShare_Rule__mdt
			WHERE Shared_Object__c = :objectName AND Active__c = TRUE];

		return rulesSharingObject;
	}

/*
	public static Schema.sObjectType getSharedObject(FormulaShare_Rule__mdt rule) {
		String sharedObjectString = rule.Shared_Object__c;
		Schema.sObjectType sharedObjectType = Schema.getGlobalDescribe().get(sharedObjectString);
		return sharedObjectType;
	}
*/


	public static List<SObjectType> getSharedObjectTypes() {

		List<SObjectType> types = new List<SObjectType>();

		// Loop through all rules to check whether they are impactedd by changes to this object
		for(AggregateResult objectType : 
			[SELECT Shared_Object__c
			FROM FormulaShare_Rule__mdt
			WHERE Active__c = TRUE
			GROUP BY Shared_Object__c]) {

			// Check whether rule shares this object
			String objName = (String) objectType.get('Shared_Object__c');
			SObjectType type = Schema.getGlobalDescribe().get(objName);
			types.add(type);
		}

		return types;
	}


	// Submits batch recalculation of all sharing
	public static void recalculateAll() {
		List<Schema.SObjectType> types = getSharedObjectTypes();
		Id batchJobId = Database.executeBatch(new ProcessFormulaShareBatch(types, batchSize), batchSize);
	}

}