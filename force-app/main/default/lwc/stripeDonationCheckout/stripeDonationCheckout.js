/**
 * stripeDonationCheckout — community-user donation flow (one-time / monthly / yearly).
 *
 * Steps: 1) amount + frequency  2) your details  3) payment.
 * On step 3 we create a Stripe Embedded Checkout Session (server-side, inline
 * price_data so any amount works) and mount it in-page via stripeCheckoutEmbedded.
 * The donor never leaves Salesforce and card data is entered on Stripe's gateway,
 * never on this LWC. onComplete → in-page thank-you.
 */
import { LightningElement, api, track } from 'lwc';
import getMyContactInfo from '@salesforce/apex/StripeDonationService.getMyContactInfo';
import createDonationCheckout from '@salesforce/apex/StripeDonationService.createDonationCheckout';
import STRIPE_FRAME from '@salesforce/resourceUrl/stripeCheckoutFrame';

const FREQS = [
    { key: 'one-time', seg: 'One-time', label: 'one-time gift' },
    { key: 'month', seg: 'Monthly', label: 'per month' },
    { key: 'year', seg: 'Yearly', label: 'per year' }
];

export default class StripeDonationCheckout extends LightningElement {
    presets = [25, 50, 100, 250, 500, 1000];
    @api orgName = 'Be Well';
    @api currencyCode = 'usd';   // set to 'inr' to show UPI etc. (methods come from your Stripe Dashboard)
    @api displayMode = 'popup';  // 'popup' (overlay) | 'inline' (in-page) — initial default
    @api showViewToggle = false; // live Popup/Inline demo switch on the payment step (set true in Builder)

    @track viewMode = 'popup';   // runtime mode, seeded from displayMode; flipped by the toggle
    get isInline() { return this.viewMode === 'inline'; }
    get showInlinePay() { return this.isStep3 && this.isInline && this.clientSecret; }
    get viewButtons() {
        return [
            { key: 'popup', label: 'Popup', class: this.viewMode === 'popup' ? 'vseg vseg_on' : 'vseg' },
            { key: 'inline', label: 'Inline', class: this.viewMode === 'inline' ? 'vseg vseg_on' : 'vseg' }
        ];
    }

    @track step = 1;          // 1 amount · 2 details · 3 payment
    @track phase = 'form';    // form | processing | success | failed
    @track showPopup = false;
    selectedPreset = 100;
    customAmount = null;
    frequency = 'one-time';

    firstName = ''; lastName = ''; email = ''; designation = '';
    contactId; prefilled = false;

    publishableKey; clientSecret; paymentRecordId;
    errorMessage;

    @track returnedFromRedirect = false;

    connectedCallback() {
        this.viewMode = this.displayMode === 'inline' ? 'inline' : 'popup';
        // Returned here after a redirect-method (UPI) payment → show the thank-you.
        try {
            if (new URLSearchParams(window.location.search).get('stripe_result') === 'success') {
                this.returnedFromRedirect = true;
                this.phase = 'success';
            }
        } catch (e) { /* ignore */ }
        getMyContactInfo()
            .then((p) => {
                if (p) {
                    this.firstName = p.firstName || '';
                    this.lastName = p.lastName || '';
                    this.email = p.email || '';
                    this.contactId = p.contactId;
                    this.prefilled = !!p.hasContact;
                }
            })
            .catch(() => { /* guest / no contact */ });
    }

    // ── derived ──
    money(n) { return '$' + Number(n || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
    get amount() { return this.customAmount ? Number(this.customAmount) : this.selectedPreset; }
    get amountDisplay() { return this.money(this.amount); }
    get frequencyLabel() { return (FREQS.find((f) => f.key === this.frequency) || FREQS[0]).label; }
    get isRecurring() { return this.frequency !== 'one-time'; }
    get donorFullName() { return `${this.firstName} ${this.lastName}`.trim(); }

    get presetButtons() {
        return this.presets.map((p) => ({
            value: p, label: '$' + p,
            class: this.selectedPreset === p && !this.customAmount ? 'pill pill_on' : 'pill'
        }));
    }
    get freqButtons() {
        return FREQS.map((f) => ({ key: f.key, label: f.seg, class: this.frequency === f.key ? 'seg seg_on' : 'seg' }));
    }
    get steps() {
        return ['Amount', 'Your details', 'Payment'].map((l, i) => {
            const n = i + 1;
            return { n, label: l, cls: 'stepdot' + (this.step === n ? ' stepdot_active' : '') + (this.step > n ? ' stepdot_done' : '') };
        });
    }
    get isForm() { return this.phase === 'form'; }
    get isStep1() { return this.isForm && this.step === 1; }
    get isStep2() { return this.isForm && this.step === 2; }
    get isStep3() { return this.isForm && this.step === 3; }
    get isProcessing() { return this.phase === 'processing'; }
    get isSuccess() { return this.phase === 'success'; }
    get isFailed() { return this.phase === 'failed'; }
    get recurringNote() { return this.isRecurring ? `You'll be charged ${this.amountDisplay} ${this.frequencyLabel} until you cancel.` : null; }
    get successHeading() { return this.firstName ? `Thank you, ${this.firstName}!` : 'Thank you!'; }
    get successMessage() {
        // After a redirect return the amount/frequency state is reset, so keep it generic.
        return this.returnedFromRedirect
            ? 'Your payment was successful. A receipt is on its way to your email.'
            : `Your ${this.frequencyLabel} of ${this.amountDisplay} was successful. A receipt is on its way to ${this.email}.`;
    }

    // ── handlers ──
    selectPreset(e) { this.selectedPreset = Number(e.currentTarget.dataset.value); this.customAmount = null; }
    handleCustom(e) { this.customAmount = e.target.value; }
    selectFreq(e) { this.frequency = e.currentTarget.dataset.key; }
    handleField(e) { this[e.target.dataset.field] = e.target.value; }

    isEmail(v) { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test((v || '').trim()); }

    next() {
        this.errorMessage = null;
        if (this.step === 1) {
            if (!this.amount || this.amount <= 0) { this.errorMessage = 'Please choose or enter an amount greater than $0.'; return; }
            if (this.amount > 100000) { this.errorMessage = 'For gifts over $100,000 please contact us directly.'; return; }
            this.step = 2;
        } else if (this.step === 2) {
            if (!this.firstName || !this.lastName) { this.errorMessage = 'Please enter your first and last name.'; return; }
            if (!this.isEmail(this.email)) { this.errorMessage = 'Please enter a valid email for your receipt.'; return; }
            this.startPayment();
        }
    }
    back() { this.errorMessage = null; if (this.step > 1) this.step -= 1; }

    // Absolute URL of the iframe page, tagged so it reports completion when a
    // redirect-based method (UPI) sends the customer back here. Enables UPI without
    // changing the card flow (cards never redirect). Blank-safe on the server side.
    get returnUrl() {
        try {
            const base = STRIPE_FRAME.indexOf('http') === 0 ? STRIPE_FRAME : window.location.origin + STRIPE_FRAME;
            // back = where to send the donor after a redirect-method (UPI) return.
            const back = encodeURIComponent(window.location.origin + window.location.pathname + '?stripe_result=success');
            return base + '/index.html?stripe_return=1&back=' + back;
        } catch (e) {
            return null;
        }
    }

    async startPayment() {
        this.phase = 'processing';
        try {
            const res = JSON.parse(await createDonationCheckout({
                amount: this.amount,
                currencyCode: this.currencyCode,
                frequency: this.frequency,
                name: this.donorFullName,
                email: this.email,
                designation: this.designation,
                returnUrl: this.returnUrl
            }));
            if (!res.success) throw new Error(res.message || 'Could not start checkout.');
            this.clientSecret = res.clientSecret;
            this.publishableKey = res.publishableKey;
            this.paymentRecordId = res.paymentRecordId;
            this.phase = 'form';
            this.step = 3;
            this.showPopup = !this.isInline;   // overlay in popup mode; inline renders in-panel
        } catch (e) {
            this.errorMessage = e && e.message ? e.message : 'Could not start checkout.';
            this.phase = 'form';
            this.step = 2;
        }
    }

    // Live switch between overlay popup and in-page inline (demo). Re-mounts the
    // Stripe payment in the other container using the existing client secret.
    switchView(e) {
        const mode = e.currentTarget.dataset.key;
        if (mode === this.viewMode) return;
        this.viewMode = mode;
        if (this.isStep3 && this.clientSecret) {
            this.showPopup = !this.isInline;   // popup → overlay; inline → in-panel
        }
    }

    handlePaymentComplete() { this.showPopup = false; this.phase = 'success'; }
    handlePaymentFailure(e) { this.errorMessage = (e.detail && e.detail.message) || 'Payment failed.'; }
    handlePaymentClose() { this.showPopup = false; this.step = 2; }

    reset() {
        this.phase = 'form'; this.step = 1; this.errorMessage = null; this.showPopup = false;
        this.customAmount = null; this.selectedPreset = 100; this.frequency = 'one-time';
        this.designation = ''; this.clientSecret = null; this.paymentRecordId = null;
    }
}