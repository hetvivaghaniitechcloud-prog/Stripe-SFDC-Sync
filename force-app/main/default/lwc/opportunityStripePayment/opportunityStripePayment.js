/**
 * opportunityStripePayment — SAMPLE org-specific wrapper (reference for consumers).
 *
 * The packaged stripePaymentButton is generic/config-agnostic. A consuming org
 * creates a thin wrapper like this that passes record-id, source-object-api and a
 * config name, then exposes it as a Quick Action on the object.
 *
 * Critical UX pattern: the component the Quick Action directly invokes fires
 * CloseActionScreenEvent. The child stripePaymentButton bubbles a composed 'close'
 * event up to here, which fires the screen-close.
 */
import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';

export default class OpportunityStripePayment extends LightningElement {
    @api recordId;
    @api objectApiName = 'Opportunity';

    // Point at a specific Stripe_Payment_Config__c (or leave blank to auto-detect by object).
    configName = 'Opportunity_Payment';

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}