provider "google-beta" {
  user_project_override = true
  region                = "asia-northeast1"
}

provider "google-beta" {
  alias                 = "no_user_project_override"
  user_project_override = false
  region                = "asia-northeast1"
}
 
provider "google" {
  region  = "asia-northeast1" # リージョンも指定
}

provider "google" {
  alias                 = "no_user_project_override"
  user_project_override = false
  region                = "asia-northeast1"
}
