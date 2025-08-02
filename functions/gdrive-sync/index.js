const admin = require('firebase-admin')
const { google } = require('googleapis')
const fs = require('fs-extra')
const path = require('path')
const os = require('os')
const { deploy } = require('firebase-tools')

const { onRequest } = require('firebase-functions/v2/https')
const { onTaskDispatched } = require('firebase-functions/v2/tasks')
const { defineString, defineSecret } = require('firebase-functions/params')
const { setGlobalOptions } = require('firebase-functions/v2')

admin.initializeApp()

// パラメータを定義します。
// これらはデプロイ時に設定する環境変数で、`functions.config()` の後継です。
// .env.gdrive-sync ファイルを作成して値を設定できます。
// 例:
// GDRIVE_FOLDER_ID="your-google-drive-folder-id"
// GDRIVE_FOLDER_URL="https://drive.google.com/drive/folders/xxxxxxxx"
const folderUrlParam = defineString('GDRIVE_FOLDER_URL', {
  description:
    'The full URL of the Google Drive folder to sync from. e.g. https://drive.google.com/drive/folders/your-folder-id'
})
const targetHostingParam = defineString('TARGET_HOSTING', {
  description: 'The Firebase Hosting target to deploy to.',
  default: 'prod'
})
// 認証用の共有シークレットを定義
const POLLING_SYNC_SECRET = defineSecret('POLLING_SYNC_SECRET', {
  description: 'A secret token to authenticate requests to the pollingSync function.'
})
// 関数のメモリやタイムアウトといったデプロイ時の設定は、通常の環境変数から読み込みます。
// Firebaseのパラメータ(defineStringなど)は、実行時のロジック内で .value() を使って値を取得するためのものです。
const FUNCTION_MEMORY = process.env.FUNCTION_MEMORY || '1GiB'
const PROJECT_ID = process.env.GCLOUD_PROJECT

// v2 SDKではGiB/MiB単位で指定します
const V2_FUNCTION_OPTIONS = {
  timeoutSeconds: 300,
  memory: FUNCTION_MEMORY
}

setGlobalOptions({ region: 'asia-northeast1' })

/**
 * Google DriveのフォルダURLからフォルダIDを抽出する
 * @param {string} url Google DriveのフォルダURL
 * @return {string | null} フォルダID。見つからない場合はnull
 */
function parseFolderIdFromUrl(url) {
  if (!url) {
    return null
  }
  // 複数の共有リンク形式に対応
  // 1. /folders/ID... (e.g., https://drive.google.com/drive/folders/xxxxxxxx?usp=drive_link)
  // 2. ?id=ID... (e.g., https://drive.google.com/open?id=xxxxxxxx)
  const match = url.match(/folders\/([a-zA-Z0-9_-]+)|[?&]id=([a-zA-Z0-9_-]+)/)

  if (match) {
    // マッチした方のキャプチャグループ (match[1] または match[2]) を返す
    return match[1] || match[2]
  }
  return null
}

/**
 * メモリ表記（"1GiB", "512MiB"など）をバイト数に変換する
 * @param {string} memoryString メモリ表記の文字列
 * @return {number} バイト数
 */
function parseMemoryToBytes(memoryString) {
  const memoryValue = parseFloat(memoryString)
  if (isNaN(memoryValue)) {
    return 0
  }
  const unit = memoryString.replace(/[0-9.]/g, '').toUpperCase()

  switch (unit) {
    case 'GIB':
      return memoryValue * 1024 * 1024 * 1024
    case 'MIB':
      return memoryValue * 1024 * 1024
    case 'KIB':
      return memoryValue * 1024
    case 'GB':
      return memoryValue * 1000 * 1000 * 1000
    case 'MB':
      return memoryValue * 1000 * 1000
    case 'KB':
      return memoryValue * 1000
    default:
      return memoryValue // バイト単位とみなす
  }
}

/**
 * 指定されたフォルダ内のファイルの合計サイズを取得する（再帰的）
 * @param {object} drive 認証済みのGoogle Drive APIクライアント
 * @param {string} folderId 対象のGoogle DriveフォルダID
 * @return {Promise<number>} 合計ファイルサイズ（バイト）
 */
async function getTotalSize(drive, folderId) {
  const files = []
  let pageToken = null
  do {
    const res = await drive.files.list({
      q: `'${folderId}' in parents and trashed = false`,
      fields: 'nextPageToken, files(id, name, mimeType, size)',
      pageToken: pageToken,
      pageSize: 1000
    })
    if (res.data.files) {
      files.push(...res.data.files)
    }
    pageToken = res.data.nextPageToken
  } while (pageToken)

  const sizes = await Promise.all(
    files.map(async (file) => {
      if (file.mimeType === 'application/vnd.google-apps.folder') {
        return await getTotalSize(drive, file.id)
      }
      // Google Docs形式のファイルはsizeが未定義の場合があるため、0として扱う
      return Number(file.size) || 0
    })
  )

  return sizes.reduce((sum, size) => sum + size, 0)
}

/**
 * ===================================================================
 *  CORE LOGIC: Google DriveからダウンロードしてHostingにデプロイする
 * ===================================================================
 */
async function downloadAndDeploy() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gdrive-sync-'))
  console.log(`Created temporary directory: ${tempDir}`)

  try {
    // 1. Google Drive APIの認証
    const auth = new google.auth.GoogleAuth({
      scopes: ['https://www.googleapis.com/auth/drive.readonly']
    })
    const drive = google.drive({ version: 'v3', auth })

    const folderUrl = folderUrlParam.value()
    const folderId = parseFolderIdFromUrl(folderUrl)

    if (!folderId) {
      throw new Error(`Invalid Google Drive folder URL: "${folderUrl}". Could not extract folder ID.`)
    }

    // ★★★ 追加: ダウンロード前に合計ファイルサイズをチェック ★★★
    console.log('Checking total file size in Google Drive...')
    const totalSize = await getTotalSize(drive, folderId)
    const memoryLimit = parseMemoryToBytes(FUNCTION_MEMORY)
    // 念のため90%のマージンを設ける
    const safeMemoryLimit = memoryLimit * 0.9

    const totalSizeMB = (totalSize / 1024 / 1024).toFixed(2)
    const memoryLimitMB = (safeMemoryLimit / 1024 / 1024).toFixed(2)

    console.log(`Total file size: ${totalSizeMB}MB`)
    console.log(`Function memory limit (safe margin 90%): ${memoryLimitMB}MB`)
    console.log('✅ Total size check successful.')

    if (totalSize > safeMemoryLimit) {
      throw new Error(
        `Total file size (${totalSizeMB}MB) exceeds 90% of the function's memory limit (${memoryLimitMB}MB). Please upgrade your plan or reduce file sizes.`
      )
    }
    // ★★★ チェックここまで ★★★

    // 2. Google Driveからファイルを再帰的にダウンロード
    console.log('Starting file download process...')
    await downloadDirectory(drive, folderId, tempDir)
    console.log('✅ Successfully downloaded all files from Google Drive.')

    // 3. Firebase Hostingへデプロイ
    console.log(`Deploying to Firebase Hosting target: ${targetHostingParam.value()}...`)

    // firebase-toolsの`deploy`は、複数サイト構成(firebase.jsonのhostingが配列)の場合、
    // `public`オプションをサポートしていません。
    // そのため、デプロイ対象のファイルが入った一時ディレクトリ内に、
    // シングルサイト構成のシンプルな`firebase.json`を動的に生成します。
    const tempFirebaseJsonPath = path.join(tempDir, 'firebase.json')
    const firebaseJsonContent = {
      hosting: {
        public: '.', // cwdからの相対パスで、カレントディレクトリを指す
        ignore: ['firebase.json', '**/.*', '**/node_modules/**']
      }
    }
    await fs.writeJson(tempFirebaseJsonPath, firebaseJsonContent)

    await deploy({
      project: PROJECT_ID,
      only: 'hosting',
      cwd: tempDir
    })
    console.log('✅ Deployment successful!')
  } finally {
    // 4. 一時ディレクトリをクリーンアップ
    await fs.remove(tempDir)
    console.log(`Cleaned up temporary directory: ${tempDir}`)
  }
}

/**
 * ===================================================================
 *  PHASE 1 / LIGHT PLAN: ポーリングによる同期
 * ===================================================================
 */
exports.pollingSync = onRequest({ ...V2_FUNCTION_OPTIONS, secrets: [POLLING_SYNC_SECRET] }, async (req, res) => {
  // --- Bearer Token Authentication ---
  const authHeader = req.headers.authorization || ''
  const [scheme, token] = authHeader.split(' ')
  const expectedToken = POLLING_SYNC_SECRET.value()

  if (scheme !== 'Bearer' || !token || token !== expectedToken) {
    console.error('Unauthorized: Invalid or missing authentication token.')
    res.status(401).send('Unauthorized')
    return
  }
  // --- End Authentication ---

  console.log('Light Plan (Polling) sync process started.')
  try {
    // 認証成功、メインロジックを実行
    await downloadAndDeploy()
    res.status(200).send('Polling sync and deploy process completed successfully.')
  } catch (error) {
    console.error('An error occurred during the polling sync process:', error)
    res.status(500).send('Polling sync and deploy process failed. Check logs for details.')
  }
})

/**
 * ===================================================================
 *  PHASE 2 / PRO PLAN: リアルタイム同期（Webhook + Tasks）
 * ===================================================================
 */

// 1. Google DriveからのWebhookを受け取り、Cloud Tasksにデプロイタスクを登録する
exports.receiveDriveNotification = onRequest({ memory: '256MiB' }, async (req, res) => {
  console.log('Pro Plan (Realtime) notification received.')
  // TODO: Cloud Tasks Clientを初期化
  // TODO: デバウンス処理（既存タスクがあればキャンセルして新しいタスクを登録）
  // TODO: `debounceDeploy` Functionをターゲットにしたタスクを作成・登録
  console.log('(TODO) Debounce deploy task has been queued.')
  res.status(200).send('Notification received and deploy task queued.')
})

// 2. Cloud Tasksから起動され、実際のデプロイ処理を実行する
exports.debounceDeploy = onTaskDispatched(V2_FUNCTION_OPTIONS, async (req) => {
  // v2では、タスクのデータは req.data に格納されます
  console.log('Pro Plan (Realtime) deploy process started.')
  try {
    await downloadAndDeploy()
  } catch (error) {
    console.error('An error occurred during the realtime deploy process:', error)
    // エラーが発生してもリトライしないように、正常終了として扱うことも検討
  }
})

/**
 * ヘルパー関数: 指定されたフォルダからファイルを再帰的にダウンロード
 * Googleドキュメントやスプレッドシートは、それぞれHTMLやCSVとしてエクスポートします。
 * @param {object} drive 認証済みのGoogle Drive APIクライアント
 * @param {string} folderId ダウンロード対象のGoogle DriveフォルダID
 * @param {string} destPath ファイルの保存先となるローカルパス
 */
async function downloadDirectory(drive, folderId, destPath) {
  // GoogleドキュメントのMIMEタイプと、エクスポート形式・拡張子のマッピング
  const EXPORT_MIMETYPES = {
    'application/vnd.google-apps.document': {
      mimeType: 'text/html',
      extension: '.html'
    },
    'application/vnd.google-apps.spreadsheet': {
      mimeType: 'text/csv',
      extension: '.csv'
    }
    // 必要に応じて他の形式（プレゼンテーションをPDFなど）も追加可能
  }

  await fs.ensureDir(destPath)

  let pageToken = null
  do {
    const res = await drive.files.list({
      q: `'${folderId}' in parents and trashed = false`,
      fields: 'nextPageToken, files(id, name, mimeType, size)',
      pageToken: pageToken,
      pageSize: 1000 // 1リクエストあたりの最大取得件数
    })

    const files = res.data.files
    if (!files || files.length === 0) {
      return
    }

    // Promise.allを使用して、フォルダ内のファイルのダウンロードを並列化
    await Promise.all(
      files.map(async (file) => {
        if (file.mimeType === 'application/vnd.google-apps.folder') {
          console.log(`Descending into sub-folder: ${file.name}`)
          const subFolderPath = path.join(destPath, file.name)
          await downloadDirectory(drive, file.id, subFolderPath) // 再帰的に処理
          return
        }

        const exportConfig = EXPORT_MIMETYPES[file.mimeType]
        if (exportConfig) {
          // Googleドキュメント形式のファイルはエクスポート処理を行う
          const fileName = `${file.name}${exportConfig.extension}`
          const localPath = path.join(destPath, fileName)
          console.log(`Exporting Google Doc: ${file.name} as ${fileName}`)
          const dest = fs.createWriteStream(localPath)

          const exportRes = await drive.files.export(
            { fileId: file.id, mimeType: exportConfig.mimeType },
            { responseType: 'stream' }
          )
          await new Promise((resolve, reject) => {
            exportRes.data.on('end', resolve).on('error', reject).pipe(dest)
          })
        } else {
          // 通常のファイルはそのままダウンロード
          const localPath = path.join(destPath, file.name)
          console.log(`Downloading file: ${file.name}`)
          const dest = fs.createWriteStream(localPath)

          const downloadRes = await drive.files.get({ fileId: file.id, alt: 'media' }, { responseType: 'stream' })
          await new Promise((resolve, reject) => {
            downloadRes.data.on('end', resolve).on('error', reject).pipe(dest)
          })
        }
      })
    )
    pageToken = res.data.nextPageToken
  } while (pageToken)
}
