@IsTest
private class StripeAdminControllerTest {

    private static final String ADMIN_PERMISSION_SET = 'Stripe_Admin';

    @TestSetup
    static void setupUserAndPermissions() {
        Profile standardProfile = [
            SELECT Id
            FROM Profile
            WHERE Name = 'Standard User'
            LIMIT 1
        ];

        User testUser = new User(
            FirstName = 'Stripe',
            LastName = 'Admin Test',
            Alias = 'strpadm',
            Email = 'stripe.admin.test@example.com',
            Username = 'stripe.admin.test.' +
                System.currentTimeMillis() +
                '@example.com',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );

        insert testUser;

        PermissionSet stripePermissionSet = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = :ADMIN_PERMISSION_SET
            LIMIT 1
        ];

        insert new PermissionSetAssignment(
            AssigneeId = testUser.Id,
            PermissionSetId = stripePermissionSet.Id
        );
    }

    @IsTest
    static void listMethods() {
        User testUser = [
            SELECT Id
            FROM User
            WHERE Alias = 'strpadm'
            LIMIT 1
        ];

        /*
         * Create records outside runAs so test data creation isn't affected
         * by user-mode object and field permissions.
         */
        insert new Stripe_Payment__c(
            Amount__c = 10,
            Currency__c = 'usd',
            Status__c = 'Completed'
        );

        insert new Stripe_Subscription__c(
            Subscription_Id__c = 'sub_a',
            Status__c = 'active'
        );

        insert new Stripe_Webhook_Log__c(
            Event_Id__c = 'evt_a',
            Event_Type__c = 'x',
            Signature_Verified__c = true
        );

        System.runAs(testUser) {
            Test.startTest();

            List<Stripe_Payment__c> payments =
                StripeAdminController.getRecentPayments();

            List<Stripe_Subscription__c> subscriptions =
                StripeAdminController.getRecentSubscriptions();

            List<Stripe_Webhook_Log__c> webhookLogs =
                StripeAdminController.getRecentWebhookLogs();

            List<String> objectNames =
                StripeAdminController.getSObjectNames();

            List<Map<String, String>> accountFields =
                StripeAdminController.getObjectFields('Account');

            List<Map<String, String>> blankFields =
                StripeAdminController.getObjectFields(null);

            Test.stopTest();

            System.assertEquals(
                1,
                payments.size(),
                'The user should be able to read Stripe payments.'
            );

            System.assertEquals(
                1,
                subscriptions.size(),
                'The user should be able to read Stripe subscriptions.'
            );

            System.assertEquals(
                1,
                webhookLogs.size(),
                'The user should be able to read webhook logs.'
            );

            System.assert(
                !objectNames.isEmpty(),
                'Accessible objects should be returned.'
            );

            System.assert(
                !accountFields.isEmpty(),
                'Accessible Account fields should be returned.'
            );

            System.assertEquals(
                0,
                blankFields.size(),
                'A blank object API name should return no fields.'
            );
        }
    }

    @IsTest
    static void invalidObjectReturnsEmptyList() {
        User testUser = [
            SELECT Id
            FROM User
            WHERE Alias = 'strpadm'
            LIMIT 1
        ];

        System.runAs(testUser) {
            Test.startTest();

            List<Map<String, String>> result =
                StripeAdminController.getObjectFields(
                    'ObjectThatDoesNotExist__c'
                );

            Test.stopTest();

            System.assertEquals(
                0,
                result.size(),
                'An invalid object API name should return an empty list.'
            );
        }
    }
}