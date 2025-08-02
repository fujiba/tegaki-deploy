# To use a remote backend (recommended for collaboration), uncomment the following block,
# create a GCS bucket for storing the state, and update the 'bucket' attribute.
# Then run 'terraform init -reconfigure'.

# terraform {
#   backend "gcs" {
#     bucket = "your-terraform-state-bucket-name" # Replace with your GCS bucket name
#     prefix = "hugo-firebase-boilerplate"        # Optional: Path within the bucket
#   }
# }