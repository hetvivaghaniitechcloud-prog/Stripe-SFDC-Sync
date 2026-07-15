/**
 * stripeMappingForm — rich per-object payment config editor (Stripe port of
 * easebuzzMappingForm). Produces the pipe-encoded field mappings the backend
 * decodes: sourceType|value|visible|required|readOnly|label|order|passToGateway
 *
 * Sections: Basic Config · Field Mapping (expandable per field) · UDF1–10 ·
 * Payment Form Options · Post-Payment Actions.
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getConfigByName from '@salesforce/apex/StripeConfigReader.getConfigByName';
import saveConfig from '@salesforce/apex/StripeConfigReader.saveConfig';
import getSObjectNames from '@salesforce/apex/StripeAdminController.getSObjectNames';
import getObjectFields from '@salesforce/apex/StripeAdminController.getObjectFields';

const FIELD = 'FIELD', HARDCODED = 'HARDCODED', BLANK = 'BLANK';

function encodeField(c) {
    return [
        c.sourceType || BLANK,
        c.value || '',
        c.visible !== false ? 'true' : 'false',
        c.required === true ? 'true' : 'false',
        c.readOnly === true ? 'true' : 'false',
        c.label || '',
        c.order != null ? String(c.order) : '',
        c.passToGateway !== false ? 'true' : 'false'
    ].join('|');
}
function decodeField(raw) {
    const d = { sourceType: BLANK, value: '', visible: true, required: false, readOnly: false, label: '', order: null, passToGateway: true };
    if (!raw || !raw.trim()) return d;
    if (!raw.includes('|')) return { ...d, sourceType: FIELD, value: raw.trim() };
    const p = raw.split('|', 8);
    return {
        sourceType: p[0] || BLANK, value: p[1] || '',
        visible: p[2] !== 'false', required: p[3] === 'true', readOnly: p[4] === 'true',
        label: p[5] || '', order: p[6] ? parseInt(p[6], 10) : null, passToGateway: p[7] !== 'false'
    };
}
function encodeOptions(o) {
    return [o.showCheckoutMode !== false ? 'true' : 'false',
            o.showNotification !== false ? 'true' : 'false',
            o.showPaymentType === true ? 'true' : 'false'].join('|');
}
function decodeOptions(raw) {
    const d = { showCheckoutMode: true, showNotification: true, showPaymentType: false };
    if (!raw || !raw.trim()) return d;
    const p = raw.split('|', 3);
    return { showCheckoutMode: p[0] !== 'false', showNotification: p[1] !== 'false', showPaymentType: p[2] === 'true' };
}

const DEFS = [
    { key: 'Amount_Field', label: 'Amount', param: 'amount', icon: '💰', section: 'core', defVisible: true, defRequired: true, defLabel: 'Amount' },
    { key: 'Name_Field', label: 'Customer Name', param: 'name', icon: '👤', section: 'core', defVisible: true, defRequired: true, defLabel: 'Full Name' },
    { key: 'Email_Field', label: 'Email', param: 'email', icon: '📧', section: 'core', defVisible: true, defRequired: true, defLabel: 'Email' },
    { key: 'Phone_Field', label: 'Phone', param: 'phone', icon: '📱', section: 'core', defVisible: true, defRequired: false, defLabel: 'Phone' },
    { key: 'Product_Info', label: 'Product Info', param: 'productinfo', icon: '📝', section: 'core', defVisible: true, defRequired: false, defLabel: 'Description' },
    ...Array.from({ length: 10 }, (_, i) => ({
        key: 'UDF' + (i + 1), label: 'UDF' + (i + 1), param: 'metadata[udf' + (i + 1) + ']', icon: '🔖',
        section: 'udf', defVisible: false, defRequired: false, defLabel: 'UDF' + (i + 1)
    }))
];

const SOURCE_OPTIONS = [
    { label: '✏️ User Input (blank)', value: BLANK },
    { label: '📋 From Record Field', value: FIELD },
    { label: '📌 Hardcoded Value', value: HARDCODED }
];
const MODE_OPTIONS = ['HOSTED', 'EMBEDDED', 'CUSTOM', 'LINK'].map((m) => ({ label: m, value: m }));
const TYPE_OPTIONS = [{ label: 'One-Time', value: 'One-Time' }, { label: 'Recurring', value: 'Recurring' }];

export default class StripeMappingForm extends LightningElement {
    @api configName = null;

    @track formData = {
        Name: '', QuickActionName: '', Source_Object: '', Checkout_Mode: 'HOSTED', Payment_Type: 'One-Time',
        Currency: 'usd', Price_Id: '', Trial_Days: null, Guest_Enabled: false, Collect_Billing_Address: true,
        Amount_Field: '', Name_Field: '', Email_Field: '', Phone_Field: '', Product_Info: '',
        UDF1: '', UDF2: '', UDF3: '', UDF4: '', UDF5: '', UDF6: '', UDF7: '', UDF8: '', UDF9: '', UDF10: '',
        Post_Success: '', Post_Value: '', Post_Flow: '', Notification: true, Is_Active: true,
        Payment_Options_Config: encodeOptions({}), ValidationRuleConfig: ''
    };
    @track options = { showCheckoutMode: true, showNotification: true, showPaymentType: false };
    @track fieldConfigs = {};
    @track objectOptions = [];
    @track fieldOptions = [];
    @track expandedKey = null;
    @track showUdf = false;
    @track isSaving = false;
    isEdit = false;

    sourceOptions = SOURCE_OPTIONS;
    modeOptions = MODE_OPTIONS;
    typeOptions = TYPE_OPTIONS;

    connectedCallback() {
        this.initConfigs();
        this.loadObjects();
        if (this.configName) { this.isEdit = true; this.loadExisting(); }
    }

    initConfigs() {
        const c = {};
        DEFS.forEach((d, i) => { c[d.key] = { sourceType: BLANK, value: '', visible: d.defVisible, required: d.defRequired, readOnly: false, label: '', order: i + 1, passToGateway: true }; });
        this.fieldConfigs = c;
        DEFS.forEach((d) => { this.formData[d.key] = encodeField(c[d.key]); });
    }

    async loadObjects() {
        try { this.objectOptions = (await getSObjectNames()).map((n) => ({ label: n, value: n })); } catch (e) { /* noop */ }
    }
    async loadFields(obj) {
        this.fieldOptions = [];
        if (!obj) return;
        try { this.fieldOptions = await getObjectFields({ objectApiName: obj }); } catch (e) { /* noop */ }
    }

    async loadExisting() {
        try {
            const res = JSON.parse(await getConfigByName({ configName: this.configName }));
            if (!res.success) { this.toast('Error', res.message, 'error'); return; }
            this.formData = { ...this.formData, ...res.data };
            const c = { ...this.fieldConfigs };
            DEFS.forEach((d) => { if (this.formData[d.key] != null) c[d.key] = decodeField(this.formData[d.key]); });
            this.fieldConfigs = c;
            this.options = decodeOptions(this.formData.Payment_Options_Config);
            if (this.formData.Source_Object) this.loadFields(this.formData.Source_Object);
        } catch (e) { this.toast('Error', 'Failed to load config.', 'error'); }
    }

    // ── row builder ──
    row(d) {
        const cfg = this.fieldConfigs[d.key] || {};
        const isField = cfg.sourceType === FIELD, isHard = cfg.sourceType === HARDCODED;
        let badge = 'User input', badgeClass = 'b-blank';
        if (isField) { badge = cfg.value || 'Pick field'; badgeClass = 'b-field'; }
        else if (isHard) { badge = '"' + (cfg.value || '') + '"'; badgeClass = 'b-hard'; }
        return {
            key: d.key, label: d.label, icon: d.icon, param: d.param,
            sourceType: cfg.sourceType, value: cfg.value, visible: cfg.visible, required: cfg.required,
            readOnly: cfg.readOnly, passToGateway: cfg.passToGateway !== false, labelOverride: cfg.label,
            order: cfg.order, isField, isHard, sourceBadge: badge, sourceBadgeClass: badgeClass,
            visibleBadge: cfg.visible ? 'Shown' : 'Hidden', visibleBadgeClass: cfg.visible ? 'b-shown' : 'b-hidden',
            requiredBadge: cfg.required ? 'Required' : 'Optional', requiredBadgeClass: cfg.required ? 'b-req' : 'b-opt',
            expanded: this.expandedKey === d.key,
            expandIcon: this.expandedKey === d.key ? 'utility:chevronup' : 'utility:edit'
        };
    }
    get coreRows() { return DEFS.filter((d) => d.section === 'core').map((d) => this.row(d)); }
    get udfRows() { return DEFS.filter((d) => d.section === 'udf').map((d) => this.row(d)); }
    get udfToggleLabel() { return this.showUdf ? '▲ Hide UDF fields' : '▼ Show UDF fields (udf1–udf10)'; }
    get title() { return this.isEdit ? 'Edit Config: ' + this.configName : 'Create Payment Config'; }
    get saveLabel() { return this.isEdit ? 'Update Config' : 'Create Config'; }
    get isRecurring() { return this.formData.Payment_Type === 'Recurring'; }
    get currencyOptions() { return ['usd', 'inr', 'eur', 'gbp', 'aud', 'sgd', 'aed'].map((c) => ({ label: c.toUpperCase(), value: c })); }

    // ── basic form ──
    handleBasic(e) {
        const f = e.target.dataset.field;
        const t = e.target.type;
        const v = (t === 'toggle' || t === 'checkbox') ? e.target.checked : (e.detail && e.detail.value !== undefined ? e.detail.value : e.target.value);
        this.formData = { ...this.formData, [f]: v };
    }
    handleObjectChange(e) {
        const v = e.detail.value;
        this.formData = { ...this.formData, Source_Object: v };
        this.initConfigs();
        this.loadFields(v);
    }
    toggleUdf() { this.showUdf = !this.showUdf; }
    handleExpand(e) { const k = e.currentTarget.dataset.key; this.expandedKey = this.expandedKey === k ? null : k; }

    // ── per-field editors ──
    update(k, patch) {
        const cfg = { ...this.fieldConfigs[k], ...patch };
        this.fieldConfigs = { ...this.fieldConfigs, [k]: cfg };
        this.formData = { ...this.formData, [k]: encodeField(cfg) };
    }
    handleSourceType(e) {
        const k = e.target.dataset.key, v = e.detail.value;
        this.update(k, v === BLANK ? { sourceType: v, value: '' } : { sourceType: v });
    }
    handleFieldPick(e) { this.update(e.detail.fieldName, { sourceType: FIELD, value: e.detail.value }); }
    handleHardcoded(e) { this.update(e.target.dataset.key, { sourceType: HARDCODED, value: e.target.value }); }
    handleVisible(e) { this.update(e.target.dataset.key, { visible: e.target.checked }); }
    handleRequired(e) { this.update(e.target.dataset.key, { required: e.target.checked }); }
    handleReadOnly(e) { this.update(e.target.dataset.key, { readOnly: e.target.checked }); }
    handlePass(e) { this.update(e.target.dataset.key, { passToGateway: e.target.checked }); }
    handleLabel(e) { this.update(e.target.dataset.key, { label: e.target.value }); }
    handleOrder(e) { const n = parseInt(e.target.value, 10); this.update(e.target.dataset.key, { order: isNaN(n) ? null : n }); }

    // ── payment options ──
    handleOption(e) {
        const k = e.target.dataset.opt;
        this.options = { ...this.options, [k]: e.target.checked };
        this.formData = { ...this.formData, Payment_Options_Config: encodeOptions(this.options) };
    }
    get optShowCheckoutMode() { return this.options.showCheckoutMode; }
    get optShowNotification() { return this.options.showNotification; }
    get optShowPaymentType() { return this.options.showPaymentType; }

    // ── save ──
    async handleSave() {
        if (!this.formData.Name) { this.toast('Validation', 'Config Name is required.', 'error'); return; }
        if (!this.formData.Source_Object) { this.toast('Validation', 'Source Object is required.', 'error'); return; }
        if (this.isRecurring && !this.formData.Price_Id) { this.toast('Validation', 'Recurring configs need a Stripe Price Id.', 'error'); return; }
        this.isSaving = true;
        try {
            const res = JSON.parse(await saveConfig({ configJson: JSON.stringify(this.formData) }));
            if (!res.success) throw new Error(res.message);
            this.toast('Saved', res.message, 'success');
            this.dispatchEvent(new CustomEvent('save'));
        } catch (e) { this.toast('Error', (e && e.message) || 'Save failed.', 'error'); }
        this.isSaving = false;
    }
    handleCancel() { this.dispatchEvent(new CustomEvent('cancel')); }
    toast(t, m, v) { this.dispatchEvent(new ShowToastEvent({ title: t, message: m, variant: v })); }
}