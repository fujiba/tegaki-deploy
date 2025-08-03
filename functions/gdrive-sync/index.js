const admin = require('firebase-admin')
const { FieldValue } = require('firebase-admin/firestore')
const { google } = require('googleapis')
const fs = require('fs-extra')
const path = require('path')
const os = require('os')
const axios = require('axios')
const { deploy } = require('firebase-tools')

const { onRequest } = require('firebase-functions/v2/https')
const { onTaskDispatched } = require('firebase-functions/v2/tasks')
const { defineString, defineSecret } = require('firebase-functions/params')
const { setGlobalOptions } = require('firebase-functions/v2')

admin.initializeApp()
const db = admin.firestore()

const serviceAccountEmailParam = defineString('SERVICE_ACCOUNT_EMAIL', {
  description: 'The service account email to run the functions with. e.g. deploy@<project-id>.iam.gserviceaccount.com'
})

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

const FUNCTION_MEMORY = process.env.FUNCTION_MEMORY || '1GiB'
const PROJECT_ID = process.env.GCLOUD_PROJECT

// v2 SDKではGiB/MiB単位で指定します
const V2_FUNCTION_OPTIONS = {
  timeoutSeconds: 300,
  memory: FUNCTION_MEMORY,
  serviceAccount: serviceAccountEmailParam
}

setGlobalOptions({ region: 'asia-northeast1' })

/**
 * このFunctionを実行しているサービスアカウントのメールアドレスを取得し、ログに出力します。
 * Google Cloudのメタデータサーバーに問い合わせて情報を取得します。
 */
const logExecutionIdentity = async () => {
  // エミュレータ環境ではスキップ
  if (process.env.FUNCTIONS_EMULATOR === 'true') {
    console.log('Running in emulator, skipping IAM check.')
    return
  }
  // メタデータサーバーのエンドポイントURL
  const url = 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'

  // メタデータサーバーへのリクエストには、このヘッダーが必須です。
  const options = {
    headers: {
      'Metadata-Flavor': 'Google'
    }
  }

  try {
    // メタデータサーバーにHTTP GETリクエストを送信
    const response = await axios.get(url, options)
    const iamEmail = response.data

    // 取得したIAM情報をログに出力
    console.log(`Function executed by IAM: ${iamEmail}`)
  } catch (error) {
    // エラーが発生した場合は、その旨をログに出力
    console.error('Failed to retrieve execution IAM.', error)
  }
}

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
 * ★★★ 変更: Google Driveのフォルダ状態（合計サイズとスナップショット）を一度に取得する ★★★
 * この関数の最初に、フォルダへのアクセス権チェックも行います。
 * @param {object} drive 認証済みのGoogle Drive APIクライアント
 * @param {string} folderId 対象のGoogle DriveフォルダID
 * @return {Promise<{totalSize: number, snapshot: string}>} 合計サイズとスナップショットを含むオブジェクト
 */
async function getDriveFolderState(drive, folderId) {
  // 1. まず、フォルダ自体にアクセスできるかを確認
  try {
    await drive.files.get({ fileId: folderId, fields: 'id' })
  } catch (error) {
    console.error(`Failed to access Google Drive folder (ID: ${folderId}). Please check permissions.`, error)
    throw new Error(
      `Failed to access Google Drive folder. Please ensure the service account has at least "Viewer" permission on the folder.`
    )
  }

  // 2. アクセスできたら、ファイル一覧を取得して状態を計算
  const files = []
  let pageToken = null
  do {
    const res = await drive.files.list({
      q: `'${folderId}' in parents and trashed = false`,
      fields: 'nextPageToken, files(id, name, mimeType, size, modifiedTime)',
      pageToken: pageToken,
      pageSize: 1000
    })
    if (res.data.files) {
      files.push(...res.data.files)
    }
    pageToken = res.data.nextPageToken
  } while (pageToken)

  let totalSize = 0
  const snapshotParts = []

  const subFolderStates = await Promise.all(
    files
      .filter((file) => file.mimeType === 'application/vnd.google-apps.folder')
      .map((folder) => getDriveFolderState(drive, folder.id))
  )

  for (const state of subFolderStates) {
    totalSize += state.totalSize
    snapshotParts.push(state.snapshot)
  }

  const currentLevelFiles = files.filter((file) => file.mimeType !== 'application/vnd.google-apps.folder')
  for (const file of currentLevelFiles) {
    totalSize += Number(file.size) || 0
    snapshotParts.push(`${file.id}:${file.modifiedTime}`)
  }

  snapshotParts.sort()
  const snapshot = snapshotParts.join('|')

  return { totalSize, snapshot }
}

/**
 * ===================================================================
 * CORE LOGIC: Google DriveからダウンロードしてHostingにデプロイする
 * ===================================================================
 */
async function downloadAndDeploy(drive, folderId) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gdrive-sync-'))
  console.log(`Created temporary directory: ${tempDir}`)
  try {
    console.log('Starting file download process...')
    await downloadDirectory(drive, folderId, tempDir)
    console.log('✅ Successfully downloaded all files from Google Drive.')

    console.log(`Deploying to Firebase Hosting target: ${targetHostingParam.value()}...`)
    const tempFirebaseJsonPath = path.join(tempDir, 'firebase.json')
    const firebaseJsonContent = {
      hosting: {
        public: '.',
        ignore: ['firebase.json', '**/.*', '**/node_modules/**']
      }
    }
    await fs.writeJson(tempFirebaseJsonPath, firebaseJsonContent)

    await deploy({
      project: PROJECT_ID,
      only: 'hosting',
      target: targetHostingParam.value(),
      cwd: tempDir
    })
    console.log('✅ Deployment successful!')
  } finally {
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
  await logExecutionIdentity()
  const authHeader = req.headers.authorization || ''
  const [scheme, token] = authHeader.split(' ')
  const expectedToken = POLLING_SYNC_SECRET.value()
  if (scheme !== 'Bearer' || !token || token !== expectedToken) {
    console.error('Unauthorized: Invalid or missing authentication token.')
    res.status(401).send('Unauthorized')
    return
  }

  console.log('Light Plan (Polling) sync process started.')
  try {
    // ★★★ 認証とDriveクライアントの初期化を一度だけ行う ★★★
    const auth = new google.auth.GoogleAuth({
      scopes: ['https://www.googleapis.com/auth/drive.readonly']
    })
    const drive = google.drive({ version: 'v3', auth })

    const folderId = parseFolderIdFromUrl(folderUrlParam.value())
    if (!folderId) {
      throw new Error('Folder ID could not be parsed from URL.')
    }

    const target = targetHostingParam.value()
    const stateDocRef = db.collection('tegaki-deploy-states').doc(target)

    // 1. 現在のDriveの状態（権限チェック、サイズ、スナップショット）を一度に取得
    const { totalSize, snapshot: currentSnapshot } = await getDriveFolderState(drive, folderId)

    // 2. Firestoreから前回のスナップショットを取得
    const doc = await stateDocRef.get()
    const previousSnapshot = doc.exists ? doc.data().snapshot : null

    // 3. スナップショットを比較
    if (currentSnapshot === previousSnapshot) {
      console.log('No changes detected in Google Drive. Skipping deployment.')
      res.status(200).send('No changes detected. Skipped deployment.')
      return
    }

    console.log('Changes detected. Starting deployment process...')

    // 4. メモリサイズをチェック
    const memoryLimit = parseMemoryToBytes(FUNCTION_MEMORY)
    const safeMemoryLimit = memoryLimit * 0.9
    const totalSizeMB = (totalSize / 1024 / 1024).toFixed(2)
    const memoryLimitMB = (safeMemoryLimit / 1024 / 1024).toFixed(2)
    console.log(`Total file size: ${totalSizeMB}MB`)
    console.log(`Function memory limit (safe margin 90%): ${memoryLimitMB}MB`)
    if (totalSize > safeMemoryLimit) {
      throw new Error(
        `Total file size (${totalSizeMB}MB) exceeds 90% of the function's memory limit (${memoryLimitMB}MB).`
      )
    }

    // 5. 変更があったので、デプロイを実行
    await downloadAndDeploy(drive, folderId)

    // 6. デプロイ成功後、新しいスナップショットをFirestoreに保存
    await stateDocRef.set({
      snapshot: currentSnapshot,
      lastUpdated: FieldValue.serverTimestamp()
    })
    console.log(`Successfully updated state for target: ${target}`)

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
