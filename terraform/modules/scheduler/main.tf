# ==============================================================================
# Cloud Scheduler 用のサービスアカウント
# ==============================================================================
# Cloud SchedulerがCloud Functionを安全に呼び出すための専用サービスアカウントを作成します。
resource "google_service_account" "scheduler_invoker" {
  project      = var.project_id
  account_id   = "tegaki-scheduler-invoker"
  display_name = "Tegaki Deploy Scheduler Invoker"
  description  = "Service account to trigger pollingSync Cloud Function from Cloud Scheduler."
}

# 作成したサービスアカウントに、Cloud Functionsを呼び出す権限(roles/cloudfunctions.invoker)を与えます。
# これにより、このサービスアカウントは指定されたFunctionの実行をトリガーできます。
resource "google_project_iam_member" "scheduler_invoker_binding" {
  project = var.project_id
  role    = "roles/cloudfunctions.invoker"
  member  = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}


# ==============================================================================
# Secret Manager から認証トークンを取得
# ==============================================================================
# Cloud Function (pollingSync)を保護している認証トークンをSecret Managerから読み込みます。
# これをSchedulerジョブのリクエストヘッダーに含めることで、安全な呼び出しを実現します。
data "google_secret_manager_secret_version" "polling_sync_secret" {
  project = var.project_id
  secret  = "POLLING_SYNC_SECRET"
}


# ==============================================================================
# Cloud Scheduler ジョブの定義
# ==============================================================================
# ライトプラン用のポーリング同期を実行するCloud Schedulerジョブを定義します。
resource "google_cloud_scheduler_job" "polling_sync_job" {
  project  = var.project_id
  region   = var.region
  name     = "tegaki-deploy-polling-sync-job"
  description = "Triggers the pollingSync function to check for Google Drive updates."

  # 実行スケジュールをcron形式で指定します。（例: 15分ごと）
  schedule = var.schedule
  time_zone = "Asia/Tokyo"
  
  # タイムアウト設定
  attempt_deadline = "300s"

  # HTTPリクエストのターゲットを設定
  http_target {
    # 呼び出すCloud FunctionのURLを指定します。
    # v2 FunctionのURLは予測可能な形式なので、ここで組み立てます。
    uri = "https://${var.region}-${var.project_id}.cloudfunctions.net/pollingSync"
    
    # HTTPメソッドはPOSTを指定
    http_method = "POST"
    
    # リクエストヘッダーに、Secret Managerから取得した認証トークンを設定します。
    headers = {
      "Authorization" = "Bearer ${data.google_secret_manager_secret_version.polling_sync_secret.secret_data}"
      "Content-Type" = "application/json"
    }
  }

  # このジョブが、上で作成したIAMバインディングに依存することを明示します。
  depends_on = [
    google_project_iam_member.scheduler_invoker_binding
  ]
}
