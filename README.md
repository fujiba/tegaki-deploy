# Tegaki Deploy

## 概要

Tegaki Deployは、Google Driveをコンテンツ管理のインターフェースとして利用し、高速かつ安全な静的ウェブサイトを公開するための自動化フレームワーク（ボイラープレート）です。本プロジェクトは、サーバーのアップデート、セキュリティ対策、コマンドラインインターフェース（CLI）による操作といった、従来の手法に伴う運用上の負担を軽減することを目的とします。

## コンセプト：直感的で簡潔なデプロイ体験の提供

本プロジェクトは、従来のFTPクライアントによるファイル転送を彷彿とさせる、直感的で簡潔なデプロイ体験の実現を目指しています。

- バージョン管理システムへの非依存: コンテンツ更新において、Git等のバージョン管理システムやCLI操作は必要ありません。
- サーバー管理の抽象化: サーバーの保守・運用はGoogleの堅牢なインフラストラクチャに委任され、利用者はインフラを意識する必要がありません。
- シンプルなコンテンツ管理: 複雑なヘッドレスCMSの管理画面を介さず、ローカルPCのフォルダ構造と同期したGoogle Driveがコンテンツ管理のインターフェースとして機能します。

本プロジェクトは、最新の静的サイトジェネレーター等の習熟に技術的障壁を感じつつも、従来の仮想プライベートサーバー（VPS）運用からの脱却を望む、デザイナー、ライター、その他すべてのコンテンツ制作者を対象としています。

## 主な特徴 (Features)

- Google DriveのCMSとしての活用: 指定されたフォルダへのファイル配置により、ウェブサイトのコンテンツが自動的に更新されます。
- サーバーレスアーキテクチャによるコスト最適化: リクエスト数に応じた従量課金制であり、トラフィックが僅少な場合、運用コストを最小限に抑制できます。
- Firebase Hostingによる高速かつ安全な配信: グローバルCDNを介した高速なコンテンツ配信と、SSL証明書の自動発行・更新により、高いパフォーマンスとセキュリティを確保します。
- Terraformによるインフラのコード管理（IaC）: Google Cloud環境の構成をコードで定義することにより、インフラの再現性と管理性を向上させます。
- GitHub ActionsによるCI/CDプロセスの自動化: コンテンツの変更検知からデプロイまでの一連のプロセスを自動化します。

## 動作原理 (How it works)

本リポジトリは、以下のワークフローを自動で構築します。

1. コンテンツ更新: 利用者がGoogle Driveの指定フォルダ内にあるファイルを追加または更新します。
2. 変更検知: GitHub Actionsが定期的に変更をポーリング、またはFirebase FunctionsがPush通知を介して即時検知します。
3. サイト構築: tegaki-deployのワークフローが、Google Driveから最新のファイル群を取得します。
4. デプロイ: 取得したファイルをFirebase Hostingへ自動的にデプロイします。

## 利用手順 (Getting Started)

本リポジトリをプロジェクトに導入するためのセットアップ手順を以下に示します。

### 前提条件

- Google Cloud Platform (GCP) アカウント
- GitHub アカウント
- ローカル環境にTerraformがインストール済みであること

### セットアップ手順

1. リポジトリのクローン:

```sh
   git clone https://github.com/fujiba/tegaki-deploy.git
   cd tegaki-deploy
```

1. 初期設定スクリプトの実行:  
   対話形式のスクリプトを実行し、GCPプロジェクトID等の必須パラメータを設定します。  
   npm run init

1. Terraformによるインフラ構築:  
   GCPへの認証後、以下のコマンドを実行します。これにより、Firebaseプロジェクト、サービスアカウント等の必須リソースが自動的にプロビジョニングされます。

   ```sh
   npm run terraform:apply
   ```

1. 認証用シークレットトークンの設定:  
   本フレームワークは、不正なアクセスからデプロイ用Functionを保護するため、共有シークレットトークンによる認証を採用しています。これにより、GitHub Actionsからの定期実行だけでなく、管理画面などからの即時実行APIとしても安全に利用できます。

   a. **トークンの生成**: 以下のコマンドを実行し、安全なランダム文字列を生成してコピーします。

   ```sh
   openssl rand -base64 32
   ```

   b. **Firebase Secretの設定**: `functions/gdrive-sync`ディレクトリで以下のコマンドを実行し、プロンプトに生成したトークンを貼り付けます。

   ```sh
   (cd functions/gdrive-sync && firebase functions:secrets:set POLLING_SYNC_SECRET)
   ```

   c. **Functionのデプロイ**: 設定したSecretを反映させるため、再度Functionをデプロイします。

   ```sh
   (cd functions/gdrive-sync && npm run deploy)
   ```

1. Google Driveフォルダの共有:
   プロビジョニングされたサービスアカウントのメールアドレスに対し、コンテンツ管理用Google Driveフォルダへのアクセス権を付与します。

1. GitHub Actionsの設定:
   a. **Function URLの登録**: GCPコンソールでデプロイした`pollingSync`関数のトリガーURLをコピーし、GitHubリポジトリのSecretsに`GDRIVE_SYNC_FUNCTION_URL`として登録します。
   b. **認証トークンの登録**: ステップ4で生成したトークンを、GitHubリポジトリのSecretsに`FUNCTION_SECRET_TOKEN`として登録します。
   c. **公開アクセスの無効化**: セキュリティを確保するため、GCPコンソールの`pollingSync`関数の権限設定から、プリンシパルが`allUsers`のエントリを削除します。

以上の手順で、初期設定は完了です。`main`ブランチへのプッシュ後、設定したスケジュール（デフォルトでは日本時間午前3:15）で自動的に同期が実行されます。

## コンテンツの更新方法

セットアップ完了後のウェブサイト更新は、主に以下の2つの方法で行うことができます。

### 1. Google Driveによる自動更新

指定されたGoogle Driveフォルダへのファイル配置によって実行されます。GitHub Actionsに設定されたスケジュールに基づき、ウェブサイトは自動的に更新されます。

### 2. 手動での即時更新

`pollingSync`関数は汎用的なAPIとして機能します。認証トークンをヘッダーに含めることで、任意のタイミングでこのAPIを呼び出し、即時デプロイを実行することが可能です。これは、管理画面からの手動更新ボタンの実装などに活用できます。

```sh
curl -X POST "YOUR_FUNCTION_URL" \
  -H "Authorization: Bearer YOUR_SECRET_TOKEN"
```

## ローカルでの開発 (Local Development)

`gdrive-sync`関数をローカルでテスト・開発する手順は以下の通りです。

1. **ローカル用Secretファイルの作成**:
   `functions/gdrive-sync`ディレクトリに`.secret.local`というファイルを作成し、認証トークンを記述します。このファイルは`.gitignore`によりリポジトリには含まれません。

   ```sh
   # functions/gdrive-sync/.secret.local
   POLLING_SYNC_SECRET=ここに生成したトークンを貼り付けます
   ```

2. **エミュレータの起動**:

   ```sh
   (cd functions/gdrive-sync && npm run serve)
   ```

3. **関数の呼び出し**:
   エミュレータが起動したら、別のターミナルから`curl`コマンドで関数を呼び出します。

   ```sh
   # [PORT]と[PROJECT_ID]はエミュレータのログに表示される値に置き換えてください
   curl -X POST "http://127.0.0.1:[PORT]/[PROJECT_ID]/asia-northeast1/pollingSync" \
     -H "Authorization: Bearer YOUR_SECRET_TOKEN"
   ```

## プロジェクトへの貢献 (Contributing)

本プロジェクトへの貢献に関心をお持ちいただき、ありがとうございます。機能改善の提案、バグ報告、プルリクエストは随時受け付けております。詳細については、Issueまたはプルリクエストにてご提案ください。

## ライセンス (License)

本プロジェクトは、[MIT License](https://www.google.com/search?q=LICENSE.txt)に基づき公開されています。
