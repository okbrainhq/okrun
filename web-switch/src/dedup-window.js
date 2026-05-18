'use strict';

class DedupWindow {
  constructor(size = 128) {
    if (!Number.isInteger(size) || size < 1 || size > 1024) {
      throw new Error('DedupWindow size must be between 1 and 1024');
    }

    this.size = size;
    this.bytes = Math.ceil(size / 8);
    this.base = null;
    this.bits = new Uint8Array(this.bytes);
  }

  reset() {
    this.base = null;
    this.bits.fill(0);
  }

  accept(seqNo) {
    if (!Number.isInteger(seqNo) || seqNo < 0 || seqNo > 0xffffffff) {
      return false;
    }

    seqNo >>>= 0;
    if (this.base === null) {
      this.base = seqNo;
      this.set(0);
      return true;
    }

    let offset = (seqNo - this.base) >>> 0;
    if (offset > 0x80000000) {
      return false;
    }

    if (offset >= this.size) {
      const shift = offset - this.size + 1;
      this.base = (this.base + shift) >>> 0;
      this.shiftLeft(shift);
      offset = (seqNo - this.base) >>> 0;
    }

    if (this.isSet(offset)) {
      return false;
    }

    this.set(offset);
    return true;
  }

  set(offset) {
    this.bits[offset >>> 3] |= 1 << (offset & 7);
  }

  isSet(offset) {
    return (this.bits[offset >>> 3] & (1 << (offset & 7))) !== 0;
  }

  shiftLeft(count) {
    if (count === 0) {
      return;
    }

    if (count >= this.size) {
      this.bits.fill(0);
      return;
    }

    const byteShift = count >>> 3;
    const bitShift = count & 7;

    if (byteShift > 0) {
      this.bits.copyWithin(0, byteShift);
      this.bits.fill(0, this.bytes - byteShift);
    }

    if (bitShift > 0) {
      for (let index = 0; index < this.bytes - 1; index += 1) {
        this.bits[index] = (
          (this.bits[index] >>> bitShift)
          | (this.bits[index + 1] << (8 - bitShift))
        ) & 0xff;
      }
      this.bits[this.bytes - 1] >>>= bitShift;
    }
  }
}

module.exports = {
  DedupWindow
};
