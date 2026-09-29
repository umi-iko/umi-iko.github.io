# サーフィン行こ 🌊

サーフィン仲間(10人くらい)で「いつ・どこへ行けるか」を共有するアプリです。
絵の具(=行き方)を選んで、カレンダーを指でなぞるだけで予定を登録できます。
スマホのホーム画面に置いて使えます(PWA)。

## 使い方(3ステップ)

1. **絵の具を選ぶ** … 「海/プール/海外」タブの下に並ぶチップから、行き方を1つタップ
2. **なぞる** … カレンダーの日付を指でなぞると、その日が塗られる(1日だけならタップ)
3. **もう一度なぞると消える** … 同じ絵の具でなぞると解除。消しゴムでまとめて消すのもOK

- 絵の具を選んでいないとき(見るモード)に日付をタップすると、その日に予定がある仲間の一覧が見られます
- 塗った日を長押しすると「一言メモ」が付けられます
- 「仲間」タブでチェックした人の予定が、カレンダーの下側に小さなバーで重なって表示されます
- 仲間が予定を更新すると、「仲間」タブに赤丸が付きます

---

## セットアップ手順(管理者向け)

### ステップ1 Supabaseで新しいプロジェクトを作る ✅済

1. https://supabase.com/dashboard → **「New project」**
2. Project name: `surf-iko` / Database Password: 自動生成 / Region: `Northeast Asia (Tokyo)` / Freeプラン
3. **「Create new project」** → 1〜2分待つ

### ステップ1-2 匿名サインインを有効にする(必須)✅済

1. 左メニュー **Authentication** → **「Sign In / Providers」**
2. **「Allow anonymous sign-ins」** をオン → **「Save changes」**

### ステップ2 データベースを作る ✅済

1. 左メニュー **SQL Editor** → 「+」→「Create a new snippet」
2. `supabase/schema.sql` の中身を**全部**貼り付けて **「Run」**
3. 結果に **`Yama`** が1行出れば成功(最初の管理者 Yama / PIN 0000 ができます)

※ 何度実行しても壊れません。「destructive operation」の確認が出たら「Run this query」でOK。

### ステップ3 URLと鍵を index.html に貼る ✅済

1. Supabaseの画面上部 **「Connect」**(または Project Settings → Data API / API Keys)
2. **Project URL** と **anon key(publishable key)** をコピー
3. `index.html` の先頭近くにある次の場所に貼る(今回はもう貼ってあります)

```js
window.SUPABASE_URL      = "https://xxxx.supabase.co";
window.SUPABASE_ANON_KEY = "sb_publishable_...";
```

⚠️ `service_role` / `secret` の鍵は**絶対に使わない・書かない**こと。

### ステップ4 GitHubにリポジトリを作ってファイルを置く

1. GitHub 右上の「+」→ **New repository** → 名前 `surf-iko` → **Public** → Create repository
2. このフォルダのファイル一式をpush(Claude Codeが実施します)

```
surf-iko/
├── index.html                       ← アプリ本体(これ1枚)
├── manifest.json                    ← PWA設定
├── sw.js                            ← オフライン/キャッシュ対策
├── icons/                           ← アイコン
├── supabase/schema.sql              ← データベース定義
├── .github/workflows/keepalive.yml  ← 自動ping
└── README.md                        ← この文書
```

### ステップ5 GitHub Pagesで公開する

1. リポジトリの **Settings** タブ → 左メニューの **Pages**
2. 「Build and deployment」の **Branch** で `main` を選び、フォルダは `/ (root)` のまま **Save**
3. 1〜2分待ってページを再読み込みすると、上に公開URLが出ます
   (`https://ユーザー名.github.io/surf-iko/` の形)

### ステップ6 自動ping用のSecretsを登録する

Supabase無料プランは、しばらく使わないと一時停止します。3日ごとに自動アクセスして防ぐ仕組みが
`.github/workflows/keepalive.yml` に入っています。動かすには「鍵の登録」が必要です。

1. リポジトリの **Settings** タブ → 左メニューの **Secrets and variables** → **Actions**
2. 緑の **「New repository secret」** をクリック
3. 1つ目を登録
   - Name: `SUPABASE_URL`
   - Secret: `https://xxxx.supabase.co`(ステップ3でコピーしたURL)
   - **Add secret**
4. もう一度 **「New repository secret」** で2つ目を登録
   - Name: `SUPABASE_ANON_KEY`
   - Secret: `sb_publishable_...`(ステップ3でコピーした鍵)
5. 動作確認: リポジトリの **Actions** タブ → 左の「Supabase Keepalive」→ 右の **「Run workflow」** →
   緑のチェックが付けば成功

### ステップ7 iPhoneのホーム画面に置く

1. iPhoneの **Safari** で公開URLを開く
2. 下の **共有ボタン(□に↑)** をタップ
3. **「ホーム画面に追加」** をタップ → 「追加」

### ステップ8 初回ログインと仲間の登録

1. アプリを開く → 名前リストから **Yama** → PIN **0000**
2. 「PINを変えますか?」が出るので **すぐ変更**(じぶんタブからでも変えられます)
3. **じぶん**タブ → 管理者メニュー → 仲間の**名前**と**初期PIN(4桁)** を登録
4. 仲間にURLと初期PINを伝える(下のテンプレをどうぞ)

---

## 仲間に送る案内文(コピペ用)

```
🌊「サーフィン行こ」はじめました!
① このURLをSafariで開いて、共有ボタン→「ホーム画面に追加」
   https://(公開URL)
② 自分の名前を選んで、PIN「(初期PIN)」でログイン
③ 絵の具を選んで、行ける日をカレンダーで指でなぞるだけ!
```

---

## 困ったときは

| 症状 | 対処 |
|---|---|
| ログインできない | Supabaseの「Allow anonymous sign-ins」がオンか確認(ステップ1-2) |
| PINを忘れた | 管理者(Yama)が「じぶん」タブ→管理者メニュー→PINリセット |
| 5回間違えてロックされた | 15分待つと解除されます |
| アプリの表示が古い | 一度閉じて開き直す(最新を自動で取りに行きます) |
| 予定が保存されない | 電波の良いところでもう一度なぞる(保存時に「保存しました」と出ます) |

## しくみ(ざっくり)

- 画面: GitHub Pages(`index.html` 1枚。フレームワークなし)
- データ: Supabase(無料枠)。RLSで「自分の予定しか書けない」よう保護
- ログイン: 匿名サインイン+4桁PIN(メール登録なし)。PINはbcryptで暗号化保存
- 停止対策: GitHub Actionsが3日ごとにSupabaseへ自動アクセス
