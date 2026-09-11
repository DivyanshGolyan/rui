/* Independent full-content oracle: hashes every decoded UTF-16 code unit and
 * structural field, without serializing a complete answer. Allocation peaks
 * inside lookup are separately recorded before this oracle runs. */
function fingerprint(value) {
    let hash = 2166136261;
    const byte = n => { hash = Math.imul(hash ^ (n & 255), 16777619) >>> 0; };
    const u32 = n => { for (let i = 0; i < 4; i++) { byte(n); n >>>= 8; } };
    const string = s => {
        u32(s.length);
        for (let i = 0; i < s.length; i++) {
            const unit = s.charCodeAt(i);
            hash = Math.imul(hash ^ (unit & 255), 16777619) >>> 0;
            hash = Math.imul(hash ^ (unit >>> 8), 16777619) >>> 0;
        }
    };
    const walk = v => {
        if (v === null) { byte(0); return; }
        if (v === false) { byte(1); return; }
        if (v === true) { byte(2); return; }
        if (typeof v === 'number') {
            byte(3);
            const view = new DataView(new ArrayBuffer(8));
            view.setFloat64(0, v === 0 ? 0 : v, true);
            for (let i = 0; i < 8; i++) byte(view.getUint8(i));
            return;
        }
        if (typeof v === 'string') { byte(4); string(v); return; }
        if (Array.isArray(v)) {
            byte(5); u32(v.length);
            for (const item of v) walk(item);
            return;
        }
        if (Object.getPrototypeOf(v) !== Object.prototype) throw Error('prototype');
        byte(6);
        const keys = Object.keys(v);
        u32(keys.length);
        for (const key of keys) { string(key); walk(v[key]); }
    };
    walk(value);
    return hash;
}
