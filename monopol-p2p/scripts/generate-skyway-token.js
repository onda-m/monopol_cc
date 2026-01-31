#!/usr/bin/env node
//
// SkyWay Room SDK (P2P Room) 用 JWT 生成スクリプト
//
// 使い方:
//   cd scripts
//   npm install jsonwebtoken uuid
//
//   # 環境変数をセット (.env ファイル or export)
//   export SKYWAY_APP_ID="your-app-id-from-console"
//   export SKYWAY_SECRET_KEY="your-secret-key-from-console"
//   node generate-skyway-token.js
//
//   # Swift に貼り付ける用（stdout にトークン1行だけ出力）:
//   node generate-skyway-token.js --print-token-for-swift
//
//   # Payload も確認したい場合:
//   node generate-skyway-token.js --show-payload
//
//   # ファイルに書き出す場合:
//   node generate-skyway-token.js --out ../path/to/skyway_token.txt
//
// .env ファイル例 (dotenv 等を使う場合):
//   SKYWAY_APP_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
//   SKYWAY_SECRET_KEY=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
//
// 生成された JWT を SkywayManager.swift の devSkywayToken に貼り付ける。

const jwt = require("jsonwebtoken");
const { v4: uuidv4 } = require("uuid");

const APP_ID = process.env.SKYWAY_APP_ID;
const SECRET_KEY = process.env.SKYWAY_SECRET_KEY;

if (!APP_ID || !SECRET_KEY) {
  console.error("Error: 環境変数が未設定です。");
  console.error("");
  console.error("  export SKYWAY_APP_ID=\"your-app-id\"");
  console.error("  export SKYWAY_SECRET_KEY=\"your-secret-key\"");
  console.error("");
  console.error("SkyWay Console ( https://console.skyway.ntt.com ) から取得してください。");
  process.exit(1);
}

const showPayload = process.argv.includes("--show-payload");
const printForSwift = process.argv.includes("--print-token-for-swift");
const outIdx = process.argv.indexOf("--out");
const outPath = outIdx >= 0 && outIdx + 1 < process.argv.length ? process.argv[outIdx + 1] : null;

const now = Math.floor(Date.now() / 1000);
const iat = now - 5;              // clock-skew 対策: 5秒前に発行扱い
const ttl = 60 * 60 * 3;         // 3時間（SkyWay上限: 3日 = 259200s）
const exp = iat + ttl;
const jti = uuidv4();

const payload = {
  jti: jti,
  iat: iat,
  exp: exp,
  scope: {
    app: {
      id: APP_ID,
      turn: true,
      actions: ["read", "write"],
    },
    rooms: {
      name: "*",
      actions: ["read", "write"],
      members: [
        {
          id: "*",
          name: "*",
          actions: ["write"],
          publication: {
            actions: ["write"],
          },
          subscription: {
            actions: ["write"],
          },
        },
      ],
    },
  },
};

const token = jwt.sign(payload, SECRET_KEY, {
  algorithm: "HS256",
  header: { typ: "JWT" },
});

if (outPath) {
  const fs = require("fs");
  fs.writeFileSync(outPath, token, "utf8");
  console.error("[generate-skyway-token] written to: " + outPath);
} else if (printForSwift) {
  // Swift の devSkywayToken に貼り付けやすい形式で stdout に出力
  console.log(token);
} else {
  // デフォルト: token を stdout に出さない（secret 漏洩防止）
  console.error("[generate-skyway-token] token generated (use --print-token-for-swift to print)");
}

if (showPayload) {
  console.error("");
  console.error("=== Payload ===");
  console.error(JSON.stringify(payload, null, 2));
}

console.error("");
console.error("[generate-skyway-token] iat=" + iat + ", exp=" + exp + ", ttl=" + ttl + "s, jti=" + jti);
console.error("Issued : " + new Date(iat * 1000).toISOString());
console.error("Expires: " + new Date(exp * 1000).toISOString());
