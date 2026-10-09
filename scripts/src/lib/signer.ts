/**
 * Signer abstraction for the market-maker bot and keeper. This code never creates, stores, logs or prints a
 * private key or seed phrase.
 *
 *  SIGNER=keystore  Decrypts the Foundry keystore ~/.foundry/keystores/$KEYSTORE_ACCOUNT (created by
 *                   `cast wallet import <name> --interactive`). Password comes from KEYSTORE_PASSWORD_FILE or an
 *                   interactive TTY prompt. The decrypted key lives only in process memory.
 *  SIGNER=rpc       Delegates signing to the RPC endpoint (eth_signTypedData_v4 / eth_sendTransaction) for
 *                   SIGNER_ADDRESS: an anvil dev account on a local fork, or a remote signer such as Clef or
 *                   web3signer in production. No key ever enters this process.
 */
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { Writable } from "node:stream";
import {
  createWalletClient,
  http,
  type Account,
  type Address,
  type Chain,
  type WalletClient,
  type Transport,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Wallet } from "ethers";

export type Signer = {
  address: Address;
  wallet: WalletClient<Transport, Chain, Account | undefined>;
  /** account argument to pass to writeContract / signTypedData */
  account: Account | Address;
};

async function promptHidden(question: string): Promise<string> {
  if (!process.stdin.isTTY) throw new Error("no TTY for password prompt; set KEYSTORE_PASSWORD_FILE");
  const muted = new Writable({ write: (_c, _e, cb) => cb() });
  const rl = createInterface({ input: process.stdin, output: muted, terminal: true });
  process.stdout.write(question);
  const answer = await new Promise<string>((res) => rl.question("", res));
  rl.close();
  process.stdout.write("\n");
  return answer;
}

export async function loadSigner(chain: Chain, rpcUrl: string): Promise<Signer> {
  const mode = process.env.SIGNER ?? "keystore";
  const transport = http(rpcUrl);

  if (mode === "rpc") {
    const address = process.env.SIGNER_ADDRESS as Address | undefined;
    if (!address) throw new Error("SIGNER=rpc requires SIGNER_ADDRESS");
    const wallet = createWalletClient({ chain, transport });
    return { address, wallet, account: address };
  }

  if (mode !== "keystore") throw new Error(`unknown SIGNER=${mode}`);
  const name = process.env.KEYSTORE_ACCOUNT ?? "blockroom-keeper";
  const dir = process.env.KEYSTORE_DIR ?? join(homedir(), ".foundry", "keystores");
  const file = join(dir, name);
  if (!existsSync(file)) {
    throw new Error(`keystore ${file} not found - create it with: cast wallet import ${name} --interactive`);
  }
  const pwFile = process.env.KEYSTORE_PASSWORD_FILE;
  const password = pwFile ? readFileSync(pwFile, "utf8").trim() : await promptHidden(`Password for ${name}: `);
  const decrypted = await Wallet.fromEncryptedJson(readFileSync(file, "utf8"), password);
  const account = privateKeyToAccount(decrypted.privateKey as `0x${string}`);
  const wallet = createWalletClient({ chain, transport, account });
  return { address: account.address, wallet, account };
}
