/**
 * searchableCombobox — type-to-search picklist that ALSO allows free-text /
 * manual entry (e.g. a relationship path like Account.Name, or HARDCODED|49.99).
 *
 * @api label, placeholder, value, options [{label, value}]
 * Emits 'change' with detail.value whenever a selection or manual edit commits.
 */
import { LightningElement, api, track } from 'lwc';

export default class SearchableCombobox extends LightningElement {
    @api label;
    @api placeholder = 'Search or type…';
    @api fieldName;          // optional caller-side identifier echoed back on change

    @track text = '';
    @track open = false;
    _options = [];

    @api
    get value() { return this.text; }
    set value(v) { this.text = v || ''; }

    @api
    get options() { return this._options; }
    set options(v) { this._options = Array.isArray(v) ? v : []; }

    get filtered() {
        const q = (this.text || '').toLowerCase();
        const list = !q
            ? this._options
            : this._options.filter(
                  (o) =>
                      (o.label && o.label.toLowerCase().includes(q)) ||
                      (o.value && o.value.toLowerCase().includes(q))
              );
        return list.slice(0, 50);
    }

    get hasResults() { return this.open && this.filtered.length > 0; }

    handleFocus() { this.open = true; }
    handleInput(e) { this.text = e.target.value; this.open = true; }

    handleSelect(e) {
        const v = e.currentTarget.dataset.value;
        this.text = v;
        this.open = false;
        this.commit();
    }

    handleBlur() {
        // delay so a click on an option registers before closing
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.open = false;
            this.commit();
        }, 200);
    }

    commit() {
        this.dispatchEvent(
            new CustomEvent('change', { detail: { value: this.text, fieldName: this.fieldName } })
        );
    }
}