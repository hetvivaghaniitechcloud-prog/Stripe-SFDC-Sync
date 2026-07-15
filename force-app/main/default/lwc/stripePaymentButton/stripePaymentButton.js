/**
 * stripePaymentButton — object-agnostic, config-driven Stripe payment launcher.
 *
 * Works as a record Quick Action, on a record page, and on an Experience Cloud
 * (guest) community page. Resolves the Stripe_Payment_Config__c for the record's
 * object, renders the mapped customer fields, then initiates payment and routes
 * by Checkout_Mode__c:
 *   HOSTED   → redirect to the Stripe-hosted session URL
 *   EMBEDDED → mount <c-stripe-checkout-embedded> (no redirect)
 *   CUSTOM   → mount <c-stripe-payment-element> (Payment Element)
 *   LINK     → show a shareable payment URL
 *
 * Critical UX pattern preserved from Easebuzz: the component the Quick Action
 * directly invokes fires CloseActionScreenEvent; child components bubble a
 * composed 'close' event up to here, which then fires the screen-close.
 */
import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { CurrentPageReference } from 'lightning/navigation';
import getConfigWithRecordValues from '@salesforce/apex/StripeConfigReader.getConfigWithRecordValues';
import getCredentialsInfo from '@salesforce/apex/StripeConfigReader.getCredentialsInfo';
import initiatePaymentLWC from '@salesforce/apex/StripePaymentEngine.initiatePaymentLWC';

export default class StripePaymentButton extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api actionName;          // optional explicit config / quick-action name
    @api sourceObjectApi;     // override object API (community usage)
    @api guestMode = false;   // true on public/guest sites

    @track fields = [];       // [{key,label,value,type,visible,readOnly,required}]
    @track stage = 'loading'; // loading | form | pay | link | done | error
    @track errorMessage;
    @track showPopup = false;

    config;
    credentials;
    publishableKey;
    clientSecret;
    hostedUrl;
    paymentRecordId;
    checkoutMode;

    @wire(CurrentPageReference) pageRef;

    connectedCallback() {
        this.init();
    }

    async init() {
        try {
            const credRaw = await getCredentialsInfo();
            this.credentials = JSON.parse(credRaw);
            if (!this.credentials.isConfigured) {
                throw new Error('Stripe is not configured. Ask your admin to complete Stripe Setup.');
            }
            this.publishableKey = this.credentials.publishableKey;

            const objApi = this.sourceObjectApi || this.objectApiName;
            const res = JSON.parse(await getConfigWithRecordValues({
                recordId: this.recordId,
                objectApiName: objApi,
                configName: this.actionName
            }));
            if (!res.success) throw new Error(res.message || 'No active payment config found.');
            this.config = res.config;
            this.checkoutMode = (this.config.checkoutMode || 'HOSTED').toUpperCase();
            this.buildFields(res.config, res.fieldValues || {});
            this.stage = 'form';
        } catch (e) {
            this.errorMessage = e && e.message ? e.message : 'Failed to load payment configuration.';
            this.stage = 'error';
        }
    }

    buildFields(config, values) {
        const defs = [
            { key: 'Amount_Field', label: 'Amount', type: 'number' },
            { key: 'Name_Field', label: 'Name', type: 'text' },
            { key: 'Email_Field', label: 'Email', type: 'email' },
            { key: 'Phone_Field', label: 'Phone', type: 'tel' },
            { key: 'Product_Info', label: 'Description', type: 'text' }
        ];
        const out = [];
        defs.forEach((d, idx) => {
            const dec = this.decode(config[d.key]);
            // Only VISIBLE fields are rendered. Hidden fields (incl. metadata pass-through)
            // are resolved server-side by the engine from the config — nothing to show here.
            if (!dec.visible) return;
            // FIELD/HARDCODED → prefill the resolved value; BLANK → user types it in.
            const resolved = (values[d.key] !== undefined && values[d.key] !== '') ? values[d.key] : dec.value;
            out.push({
                key: d.key,
                label: dec.label || d.label,
                value: resolved,
                type: d.type,
                readOnly: dec.readOnly,                                  // read-only renders disabled
                required: dec.required || d.key === 'Amount_Field',
                order: dec.order != null ? dec.order : idx + 1
            });
        });
        // Respect the configured display order.
        out.sort((a, b) => a.order - b.order);
        this.fields = out;
    }

    decode(raw) {
        const def = { sourceType: 'BLANK', value: '', visible: true, required: false, readOnly: false, label: '', order: null, passToGateway: true };
        if (!raw) return def;
        if (raw.indexOf('|') === -1) return { ...def, sourceType: 'FIELD', value: raw };
        const p = raw.split('|');
        return {
            sourceType: p[0] || 'BLANK',
            value: p[1] || '',
            visible: p[2] !== 'false',
            required: p[3] === 'true',
            readOnly: p[4] === 'true',
            label: p[5] || '',
            order: p[6] ? parseInt(p[6], 10) : null,
            passToGateway: p[7] !== 'false'
        };
    }

    handleFieldChange(event) {
        const key = event.target.dataset.key;
        // reassign so amount/customer getters recompute
        this.fields = this.fields.map((x) => (x.key === key ? { ...x, value: event.target.value } : x));
    }

    // ── rich-UI derived state ──
    fieldVal(key) { const f = this.fields.find((x) => x.key === key); return f ? f.value : null; }
    get amountDisplay() {
        const a = parseFloat(this.fieldVal('Amount_Field'));
        if (!a || a <= 0) return null;
        const cur = (this.config && this.config.currency ? this.config.currency : 'usd').toUpperCase();
        try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: cur }).format(a); }
        catch (e) { return a.toFixed(2) + ' ' + cur; }
    }
    get customerDisplay() { return this.fieldVal('Name_Field') || null; }
    get hasFields() { return this.fields && this.fields.length > 0; }
    get isLinkMode() { return this.checkoutMode === 'LINK'; }
    get payLabel() { return this.isLinkMode ? 'Generate Link' : 'Collect Payment'; }
    get payIcon() { return this.isLinkMode ? 'utility:link' : 'utility:money'; }

    async handleCopyLink() {
        try {
            if (navigator.clipboard && this.hostedUrl) await navigator.clipboard.writeText(this.hostedUrl);
            else { const el = this.template.querySelector('[data-id="pay-url"]'); if (el) { el.select(); document.execCommand('copy'); } }
            this.dispatchEvent(new ShowToastEvent({ title: 'Copied', message: 'Payment link copied to clipboard.', variant: 'success' }));
        } catch (e) { /* clipboard blocked — user can select manually */ }
    }

    // Runtime mode picker — only modes enabled in Stripe Credentials are offered.
    get availableModes() {
        if (!this.credentials) return [];
        const opts = [];
        if (this.credentials.hostedEnabled) opts.push({ label: 'Hosted (redirect)', value: 'HOSTED' });
        if (this.credentials.embeddedEnabled) opts.push({ label: 'Embedded (in-page)', value: 'EMBEDDED' });
        if (this.credentials.customElementEnabled) opts.push({ label: 'Custom (Payment Element)', value: 'CUSTOM' });
        if (this.credentials.linkEnabled) opts.push({ label: 'Payment Link', value: 'LINK' });
        return opts;
    }
    get showModeSelector() { return this.stage === 'form' && this.availableModes.length > 1; }
    handleModeChange(event) { this.checkoutMode = event.detail.value; }

    get fieldValueMap() {
        const m = {};
        this.fields.forEach((f) => (m[f.key] = f.value));
        return m;
    }

    async handlePay() {
        this.errorMessage = undefined;
        const vals = this.fieldValueMap;
        const amount = parseFloat(vals.Amount_Field);
        if (!amount || amount <= 0) {
            this.errorMessage = 'Please enter a valid amount.';
            return;
        }
        this.stage = 'loading';
        try {
            const resStr = await initiatePaymentLWC({
                recordId: this.recordId,
                amount: amount,
                currencyCode: this.config.currency,
                customerName: vals.Name_Field,
                customerEmail: vals.Email_Field,
                customerPhone: vals.Phone_Field,
                productInfo: vals.Product_Info,
                checkoutMode: this.checkoutMode,
                configName: this.config.configName,
                hiddenParamsJson: null
            });
            const res = JSON.parse(resStr);
            if (!res.success) throw new Error(res.errorMessage || 'Payment initiation failed.');

            this.paymentRecordId = res.paymentRecordId;
            this.publishableKey = res.publishableKey || this.publishableKey;
            this.clientSecret = res.clientSecret;
            this.hostedUrl = res.hostedUrl;
            this.routeByMode(res);
        } catch (e) {
            this.errorMessage = e && e.message ? e.message : 'Payment failed.';
            this.stage = 'error';
        }
    }

    routeByMode(res) {
        switch (this.checkoutMode) {
            case 'EMBEDDED':
            case 'CUSTOM':
                // Both render in the iframe popup (Stripe runs outside Lightning Web
                // Security, so no js.stripe.com loadScript / CSP script-src needed).
                this.showPopup = true;
                this.stage = 'pay';
                break;
            case 'LINK':
                this.stage = 'link';
                break;
            case 'HOSTED':
            default:
                if (res.hostedUrl) {
                    window.open(res.hostedUrl, '_self');
                    this.stage = 'done';
                } else {
                    this.errorMessage = 'No checkout URL returned.';
                    this.stage = 'error';
                }
        }
    }

    handleChildSuccess() {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Payment submitted', message: 'Your payment is being processed.', variant: 'success'
        }));
        this.showPopup = false;
        this.stage = 'done';
        this.closeScreen();
    }

    handleChildFailure(event) {
        this.errorMessage = (event.detail && event.detail.message) || 'Payment failed.';
    }

    // Children bubble a composed 'close'; the quick-action component fires the screen-close.
    handleChildClose() {
        this.showPopup = false;
        this.closeScreen();
    }

    handleClose() {
        this.closeScreen();
    }

    closeScreen() {
        // In a Quick Action this closes the screen; on a community page it is a
        // harmless no-op, so we also emit a composed 'close' for wrapper components.
        this.dispatchEvent(new CloseActionScreenEvent());
        this.dispatchEvent(new CustomEvent('close', { bubbles: true, composed: true }));
    }

    get isLoading() { return this.stage === 'loading'; }
    get showForm() { return this.stage === 'form'; }
    get showPay() { return this.stage === 'pay'; }
    get showLink() { return this.stage === 'link'; }
    get showError() { return this.stage === 'error'; }
    get returnUrl() { return this.credentials ? this.credentials.returnUrl : null; }
}