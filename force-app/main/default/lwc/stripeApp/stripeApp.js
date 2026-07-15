/**
 * stripeApp — Stripe Setup console. Multi-tab admin UI:
 *   Credentials · Payment Configs · Transactions · Subscriptions · Webhooks
 * Wired to the packaged Apex (config-agnostic; admins configure at runtime).
 */
import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCredentialsInfo from '@salesforce/apex/StripeConfigReader.getCredentialsInfo';
import saveCredentials from '@salesforce/apex/StripeConfigReader.saveCredentials';
import testConnection from '@salesforce/apex/StripeConfigReader.testConnection';
import registerWebhookApex from '@salesforce/apex/StripeConfigReader.registerWebhook';
import getAllConfigs from '@salesforce/apex/StripeConfigReader.getAllConfigs';
import saveConfig from '@salesforce/apex/StripeConfigReader.saveConfig';
import deleteConfig from '@salesforce/apex/StripeConfigReader.deleteConfig';
import getRecentPayments from '@salesforce/apex/StripeAdminController.getRecentPayments';
import getRecentSubscriptions from '@salesforce/apex/StripeAdminController.getRecentSubscriptions';
import getRecentWebhookLogs from '@salesforce/apex/StripeAdminController.getRecentWebhookLogs';
import getSObjectNames from '@salesforce/apex/StripeAdminController.getSObjectNames';
import getObjectFields from '@salesforce/apex/StripeAdminController.getObjectFields';
import retryFailed from '@salesforce/apex/StripeWebhookRetry.retryFailedLWC';

const ENV_OPTIONS = [{ label: 'Test (Sandbox)', value: 'test' }, { label: 'Live (Production)', value: 'live' }];
const AUTH_MODE_OPTIONS = [
    { label: 'Secret Key (Bearer) — per request', value: 'KEY' },
    { label: 'Named Credential (Custom / OAuth 2.0)', value: 'NAMED_CREDENTIAL' }
];
const CURRENCY_OPTIONS = ['usd', 'inr', 'eur', 'gbp', 'aud', 'cad', 'sgd', 'aed'].map((c) => ({ label: c.toUpperCase(), value: c }));
const REDIRECT_OPTIONS = [
    { label: 'New tab (recommended)', value: 'newtab' },
    { label: 'Same window', value: 'same' }
];
const WEBHOOK_EVENTS = [
    'checkout.session.completed — payment / subscription confirmed',
    'checkout.session.expired — abandoned / cancelled checkout',
    'payment_intent.succeeded / payment_failed / canceled — card outcome',
    'charge.succeeded / failed / refunded — attempts & refunds',
    'invoice.paid / invoice.payment_failed — recurring renewals',
    'customer.subscription.created | updated | deleted — subscription lifecycle'
];
const MODE_OPTIONS = ['HOSTED', 'EMBEDDED', 'CUSTOM', 'LINK'].map((m) => ({ label: m, value: m }));
const TYPE_OPTIONS = ['One-Time', 'Recurring'].map((m) => ({ label: m, value: m }));

const PAY_COLS = [
    { label: 'Name', fieldName: 'Name' },
    { label: 'Amount', fieldName: 'Amount__c', type: 'number' },
    { label: 'Currency', fieldName: 'Currency__c' },
    { label: 'Status', fieldName: 'Status__c' },
    { label: 'Mode', fieldName: 'Checkout_Mode__c' },
    { label: 'Type', fieldName: 'Payment_Type__c' },
    { label: 'Email', fieldName: 'Customer_Email__c' },
    { label: 'Created', fieldName: 'CreatedDate', type: 'date' }
];
const SUB_COLS = [
    { label: 'Subscription', fieldName: 'Subscription_Id__c' },
    { label: 'Status', fieldName: 'Status__c' },
    { label: 'Interval', fieldName: 'Interval__c' },
    { label: 'Amount', fieldName: 'Amount__c', type: 'number' },
    { label: 'Period End', fieldName: 'Current_Period_End__c', type: 'date' },
    { label: 'Cancel @ End', fieldName: 'Cancel_At_Period_End__c', type: 'boolean' }
];
const LOG_COLS = [
    { label: 'Event Id', fieldName: 'Event_Id__c' },
    { label: 'Type', fieldName: 'Event_Type__c' },
    { label: 'Verified', fieldName: 'Signature_Verified__c', type: 'boolean' },
    { label: 'Status', fieldName: 'Processing_Status__c' },
    { label: 'Created', fieldName: 'CreatedDate', type: 'date' }
];
const CFG_COLS = [
    { label: 'Name', fieldName: 'Name' },
    { label: 'Object', fieldName: 'Source_Object' },
    { label: 'Mode', fieldName: 'Checkout_Mode' },
    { label: 'Type', fieldName: 'Payment_Type' },
    { label: 'Active', fieldName: 'Is_Active', type: 'boolean' },
    { type: 'button-icon', typeAttributes: { iconName: 'utility:edit', name: 'edit', title: 'Edit' } },
    { type: 'button-icon', typeAttributes: { iconName: 'utility:delete', name: 'delete', title: 'Delete' } }
];

export default class StripeApp extends LightningElement {
    envOptions = ENV_OPTIONS;
    authModeOptions = AUTH_MODE_OPTIONS;
    currencyOptions = CURRENCY_OPTIONS;
    redirectOptions = REDIRECT_OPTIONS;
    webhookEvents = WEBHOOK_EVENTS;
    modeOptions = MODE_OPTIONS;
    typeOptions = TYPE_OPTIONS;
    payCols = PAY_COLS;
    subCols = SUB_COLS;
    logCols = LOG_COLS;
    cfgCols = CFG_COLS;

    @track cred = {};
    @track credInfo = {};
    openSections = ['auth'];
    @track configView = 'list';   // 'list' | 'form'
    @track editConfigName = null;
    @track newCfg = { Checkout_Mode: 'HOSTED', Payment_Type: 'One-Time', Is_Active: true };
    @track configs = [];
    @track payments = [];
    @track subscriptions = [];
    @track logs = [];
    @track objectOptions = [];
    @track fieldOptions = [];

    connectedCallback() {
        this.loadCredentials();
        this.loadConfigs();
        this.loadObjects();
    }

    async loadObjects() {
        try {
            const names = await getSObjectNames();
            this.objectOptions = (names || []).map((n) => ({ label: n, value: n }));
        } catch (e) { /* non-fatal */ }
    }

    async loadFields(objectApiName) {
        this.fieldOptions = [];
        if (!objectApiName) return;
        try { this.fieldOptions = await getObjectFields({ objectApiName }); }
        catch (e) { /* non-fatal */ }
    }

    // searchableCombobox change → write back to newCfg; reload fields when the object changes
    handleSearchChange(e) {
        const { fieldName, value } = e.detail;
        this.newCfg = { ...this.newCfg, [fieldName]: value };
        if (fieldName === 'Source_Object') this.loadFields(value);
    }

    // ── Credentials ──
    async loadCredentials() {
        try {
            const i = JSON.parse(await getCredentialsInfo());
            this.credInfo = i;
            this.cred = {
                environment: i.environment || 'test',
                authMode: i.authMode || 'KEY',
                apiVersion: i.apiVersion,
                namedCredential: i.namedCredential,
                defaultCurrency: i.defaultCurrency || 'usd',
                defaultProductInfo: i.defaultProductInfo,
                hostedRedirect: i.hostedRedirect || 'newtab',
                webhookBaseUrl: i.webhookBaseUrl,
                successUrl: i.successUrl,
                cancelUrl: i.cancelUrl,
                returnUrl: i.returnUrl,
                logoUrl: i.logoUrl,
                apiTimeoutSec: i.apiTimeoutSec,
                hostedEnabled: i.hostedEnabled,
                embeddedEnabled: i.embeddedEnabled,
                customElementEnabled: i.customElementEnabled,
                linkEnabled: i.linkEnabled
            };
        } catch (e) { this.toast('Error', this.msg(e), 'error'); }
    }

    async testConn() {
        try {
            const r = JSON.parse(await testConnection());
            if (!r.success) throw new Error(r.message);
            this.toast('Connected', `Stripe account ${r.accountId || ''} · country ${r.country || ''} · ${(r.defaultCurrency || '').toUpperCase()}`, 'success');
        } catch (e) { this.toast('Connection failed', this.msg(e), 'error'); }
    }

    async registerWebhook() {
        try {
            const r = JSON.parse(await registerWebhookApex());
            if (!r.success) throw new Error(r.message);
            this.toast('Webhook registered', 'Endpoint ' + (r.endpointId || '') + ' created in Stripe and the signing secret was saved automatically.', 'success');
            this.loadCredentials();
        } catch (e) { this.toast('Registration failed', this.msg(e), 'error'); }
    }

    copyWebhookUrl() {
        const url = this.credInfo.webhookUrl || '';
        const el = document.createElement('textarea');
        el.value = url; document.body.appendChild(el); el.select();
        try { document.execCommand('copy'); this.toast('Copied', 'Webhook URL copied.', 'success'); }
        catch (e) { /* clipboard blocked */ }
        document.body.removeChild(el);
    }

    get isKeyMode() { return this.cred.authMode !== 'NAMED_CREDENTIAL'; }
    get isNcMode() { return this.cred.authMode === 'NAMED_CREDENTIAL'; }
    get webhookUrl() { return this.credInfo ? this.credInfo.webhookUrl : ''; }
    handleCredChange(e) {
        const t = e.target.type;
        const isBool = t === 'checkbox' || t === 'toggle';
        this.cred[e.target.dataset.field] = isBool ? e.target.checked : e.target.value;
    }
    async saveCred() {
        try {
            const res = JSON.parse(await saveCredentials({ credJson: JSON.stringify(this.cred) }));
            if (!res.success) throw new Error(res.message);
            this.toast('Saved', 'Credentials saved.', 'success');
            this.loadCredentials();
        } catch (e) { this.toast('Error', this.msg(e), 'error'); }
    }

    // ── Configs ──
    async loadConfigs() {
        try { this.configs = JSON.parse(await getAllConfigs()); }
        catch (e) { this.toast('Error', this.msg(e), 'error'); }
    }
    handleCfgChange(e) { this.newCfg[e.target.dataset.field] = e.target.type === 'checkbox' ? e.target.checked : e.target.value; }
    async saveCfg() {
        try {
            if (!this.newCfg.Name) { this.toast('Missing', 'Config name is required.', 'warning'); return; }
            const res = JSON.parse(await saveConfig({ configJson: JSON.stringify(this.newCfg) }));
            if (!res.success) throw new Error(res.message);
            this.toast('Saved', res.message, 'success');
            this.newCfg = { Checkout_Mode: 'HOSTED', Payment_Type: 'One-Time', Is_Active: true };
            this.loadConfigs();
        } catch (e) { this.toast('Error', this.msg(e), 'error'); }
    }
    async handleCfgRow(e) {
        const action = e.detail.action.name;
        const row = e.detail.row;
        if (action === 'delete') {
            try {
                await deleteConfig({ configName: row.Name });
                this.toast('Deleted', 'Config removed.', 'success');
                this.loadConfigs();
            } catch (err) { this.toast('Error', this.msg(err), 'error'); }
        } else if (action === 'edit') {
            this.editConfigName = row.Name;
            this.configView = 'form';
        }
    }

    // ── Payment Config list ↔ mapping form ──
    newConfig() { this.editConfigName = null; this.configView = 'form'; }
    handleFormSave() { this.configView = 'list'; this.loadConfigs(); }
    handleFormCancel() { this.configView = 'list'; }
    get showConfigList() { return this.configView === 'list'; }
    get showConfigForm() { return this.configView === 'form'; }

    // ── Data tabs ──
    async loadPayments() { try { this.payments = await getRecentPayments(); } catch (e) { this.toast('Error', this.msg(e), 'error'); } }
    async loadSubscriptions() { try { this.subscriptions = await getRecentSubscriptions(); } catch (e) { this.toast('Error', this.msg(e), 'error'); } }
    async loadLogs() { try { this.logs = await getRecentWebhookLogs(); } catch (e) { this.toast('Error', this.msg(e), 'error'); } }
    async retryWebhooks() {
        try {
            const res = JSON.parse(await retryFailed());
            this.toast('Retry', 'Retried ' + (res.retried || 0) + ' event(s).', 'success');
            this.loadLogs();
        } catch (e) { this.toast('Error', this.msg(e), 'error'); }
    }

    handleTabActive(e) {
        const t = e.target.value;
        if (t === 'payments') this.loadPayments();
        else if (t === 'subscriptions') this.loadSubscriptions();
        else if (t === 'webhooks') this.loadLogs();
    }

    get isConfigured() { return this.credInfo && this.credInfo.isConfigured; }
    get statusVariant() { return this.isConfigured ? 'success' : 'warning'; }
    get statusText() {
        return this.isConfigured
            ? `Configured (${this.credInfo.environment}) — publishable ${this.credInfo.publishableKey || ''}`
            : 'Not configured — enter your Stripe keys below.';
    }

    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
    msg(e) { return e && e.body && e.body.message ? e.body.message : (e && e.message ? e.message : 'Unexpected error'); }
}