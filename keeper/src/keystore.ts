// Decrypts a Web3 Secret Storage v3 keystore (the format `cast wallet new` and `cast wallet import` write) in memory.
// scrypt or pbkdf2 key derivation, aes-128-ctr, the mac keccak256(derivedKey[16..32] ++ ciphertext). the key never
// leaves this process and is never logged.

import { createDecipheriv, pbkdf2Sync, scryptSync } from "node:crypto";
import { readFileSync } from "node:fs";
import { bytesToHex, concat, keccak256, type Hex } from "viem";

export function decryptKeystore(json: string, password: string): Hex {
  const k = JSON.parse(json);
  const c = k.crypto ?? k.Crypto;
  if (k.version !== 3 || !c) throw new Error("keystore: not a v3 keystore");
  if (c.cipher !== "aes-128-ctr") throw new Error(`keystore: cipher ${c.cipher} is not supported`);
  const p = c.kdfparams;
  const salt = Buffer.from(p.salt, "hex");
  let dk: Buffer;
  if (c.kdf === "scrypt") {
    dk = scryptSync(password, salt, p.dklen, { N: p.n, r: p.r, p: p.p, maxmem: 256 * p.n * p.r + 1024 * 1024 });
  } else if (c.kdf === "pbkdf2") {
    if (p.prf !== "hmac-sha256") throw new Error(`keystore: prf ${p.prf} is not supported`);
    dk = pbkdf2Sync(password, salt, p.c, p.dklen, "sha256");
  } else throw new Error(`keystore: kdf ${c.kdf} is not supported`);
  const ct = Buffer.from(c.ciphertext, "hex");
  const mac = keccak256(concat([new Uint8Array(dk.subarray(16, 32)), new Uint8Array(ct)]));
  if (mac.slice(2) !== String(c.mac).toLowerCase()) throw new Error("keystore: wrong password");
  const d = createDecipheriv("aes-128-ctr", dk.subarray(0, 16), Buffer.from(c.cipherparams.iv, "hex"));
  const key = Buffer.concat([d.update(ct), d.final()]);
  return bytesToHex(new Uint8Array(key));
}

// the password file holds the password alone; a trailing newline is dropped
export function readKeystore(path: string, passwordFile: string): Hex {
  const pw = readFileSync(passwordFile, "utf8").replace(/\r?\n$/, "");
  return decryptKeystore(readFileSync(path, "utf8"), pw);
}
