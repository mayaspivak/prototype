# Specify the provider, here
provider "google" {
  project = var.project_id
  region  = var.compute_region
}

/* 
 * [BEGIN] GCS Resources
 */

# Raw data landing zone for data ingestion
resource "google_storage_bucket" "gcs_data_ingestion_landing_bucket" {
  name          = var.gcs_landing_bucket
  location      = var.gcs_region
  force_destroy = true # This forces deletion of objects created in bucket post provisioning
  # https://www.terraform.io/docs/providers/google/r/storage_bucket.html#force_destroy
}

# Bucket for storing the GCF code
resource "google_storage_bucket" "gcf_code" {
  name     = var.gcf_code_bucket
  location = var.gcs_region
}

/*
 * [END] GCS Resources
 */

/* 
 * [BEGIN] Test File Upload
 * This is just adding temporary files for testing the SQL queries.
 * These should be removed when the pipelines for adding these files are copmleted,
 * and the SQL queries should point to those.
 */

resource "google_storage_bucket_object" "file_pdccr" {
  name   = "covid_19_pdccr.csv"
  bucket = google_storage_bucket.gcs_data_ingestion_landing_bucket.name
  source = "./testing_data_files/Provisional_COVID-19_Death_Counts_by_County_and_Race.csv"
}

resource "google_storage_bucket_object" "file_ucf" {
  name   = "Urgent_Care_Facilities.csv"
  bucket = google_storage_bucket.gcs_data_ingestion_landing_bucket.name
  source = "./testing_data_files/Urgent_Care_Facilities.csv"
}

/*
 * [END] Test File Upload
 */

/*
 * [BEGIN] BigQuery Setup
 */

# Create a BigQuery dataset
resource "google_bigquery_dataset" "bq_dataset" {
  dataset_id = var.bq_dataset_name
  location   = "US"
}

/*
 * [BEGIN] Table Creation
 * Manually create tables for pdccr and ucf for testing. Much like the CSV files, these
 * are just temporary loads until they are dynamically loaded in by the ingest pipelines.
 */

# PDCCR table
resource "google_bigquery_table" "bq_table_pdccr" {
  dataset_id = google_bigquery_dataset.bq_dataset.dataset_id
  table_id   = "cdc_pdccr"
}

# PDCCR load
resource "google_bigquery_job" "bq_job_load_pdccr" {
  job_id = "pdccr_load${formatdate("YYYYMMDDhhmmss", timestamp())}"

  load {
    source_uris = [
      "gs://${var.gcs_landing_bucket}/covid_19_pdccr.csv",
    ]

    destination_table {
      project_id = google_bigquery_table.bq_table_pdccr.project
      dataset_id = google_bigquery_table.bq_table_pdccr.dataset_id
      table_id   = google_bigquery_table.bq_table_pdccr.table_id
    }

    skip_leading_rows = 1

    write_disposition = "WRITE_TRUNCATE"
    autodetect        = true
  }
}

# UCF table
resource "google_bigquery_table" "bq_table_ucf" {
  dataset_id = google_bigquery_dataset.bq_dataset.dataset_id
  table_id   = "ucf"
}

# UCF load
resource "google_bigquery_job" "bq_job_load_ucf" {
  job_id = "ucf_load${formatdate("YYYYMMDDhhmmss", timestamp())}"

  load {
    source_uris = [
      "gs://${var.gcs_landing_bucket}/Urgent_Care_Facilities.csv",
    ]

    destination_table {
      project_id = google_bigquery_table.bq_table_ucf.project
      dataset_id = google_bigquery_table.bq_table_ucf.dataset_id
      table_id   = google_bigquery_table.bq_table_ucf.table_id
    }

    skip_leading_rows = 1

    write_disposition = "WRITE_TRUNCATE"
    autodetect        = true
  }
}

/*
 * [END] Table Creation
 */

resource "google_bigquery_table" "bqt_pdccr_ucf_joined" {
  dataset_id = google_bigquery_dataset.bq_dataset.dataset_id
  table_id   = "pdccr_ucf_joined"

  labels = {
    "derived-table" = "yes"
  }
}
# Use the ./sql/pdccr.sql file
resource "google_bigquery_job" "bq_job_pdccr_ucf_joined" {
  depends_on = [google_bigquery_job.bq_job_load_pdccr, google_bigquery_job.bq_job_load_ucf]
  job_id     = "pdccrucfjoin${formatdate("YYYYMMDDhhmmss", timestamp())}"

  query {
    query = file("./sql/pdccr.sql")

    destination_table {
      table_id = google_bigquery_table.bqt_pdccr_ucf_joined.id
    }

    allow_large_results = true
  }
}

/*
 * [END] BigQuery Setup
 */

/*
 * [BEGIN] GCF code upload Setup
 */

# Create a ZIP of the /python folder.
data "archive_file" "gcf_ingestion_zip" {
  type        = "zip"
  source_dir  = "${var.gcf_code_path}/python/"
  output_path = "${var.gcf_code_path}/gcf_ingestion.zip"
}

# Place the ZIP file into the gcf_code bucket
resource "google_storage_bucket_object" "gcf_ingestion_code" {
  name   = "gcf_ingestion.zip"
  bucket = google_storage_bucket.gcf_code.name
  source = data.archive_file.gcf_ingestion_zip.output_path
}

/*
 * [END] GCF code upload Setup
 */

/*
 * [BEGIN] GCF upload to GCS Setup
 */

# Configure the actual Cloud Function for uploading data to GCS
resource "google_cloudfunctions_function" "data_ingestion_to_gcs" {
  name                  = var.gcf_upload_to_gcs_name
  description           = "Downloads data files from the internet and uploads to a GCS bucket"
  available_memory_mb   = 256
  source_archive_bucket = google_storage_bucket.gcf_code.name
  source_archive_object = google_storage_bucket_object.gcf_ingestion_code.name
  timeout               = 120
  entry_point           = "ingest_data"
  runtime               = "python37"
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.upload_to_gcs.name
  }
  environment_variables = {
    PROJECT_ID                 = var.project_id
    NOTIFY_DATA_INGESTED_TOPIC = var.notify_data_ingested_topic
  }
}

/*
 * [END] GCF upload to GCS Setup
 */

/*
 * [BEGIN] GCF GCS to BigQuery Setup
 */

# Configure Cloud Function for moving data from GCS to BigQuery
resource "google_cloudfunctions_function" "gcs_to_bq" {
  name                  = var.gcf_gcs_to_bq_name
  description           = "Moves data from GCS bucket to BigQuery"
  available_memory_mb   = 256
  source_archive_bucket = google_storage_bucket.gcf_code.name
  source_archive_object = google_storage_bucket_object.gcf_ingestion_code.name
  timeout               = 500
  entry_point           = "ingest_bucket_to_bq"
  runtime               = "python37"
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = var.notify_data_ingested_topic
  }
  environment_variables = {
    DATASET_NAME = var.bq_dataset_name
  }
}

/*
 * [END] GCF GCS to BigQuery Setup
 */

/*
 * [BEGIN] Service Account Setup
 */

# Service account used to invoke the cloud run service through the push subscription.
resource "google_service_account" "ingestion_invoker_identity" {
  # The account id that is used to generate the service account email. Must be 6-30 characters long and
  # match the regex [a-z]([-a-z0-9]*[a-z0-9]).
  account_id = var.ingestion_invoker_identity_id
}

# Service account whose identity is used when running the ingestion service.
resource "google_service_account" "ingestion_runner_identity" {
  # The account id that is used to generate the service account email. Must be 6-30 characters long and
  # match the regex [a-z]([-a-z0-9]*[a-z0-9]).
  account_id = var.ingestion_runner_identity_id
}

# Give the ingestion invoker service account the existing invoker role so that it can call the ingestion service.
resource "google_cloud_run_service_iam_member" "ingestion_invoker_binding" {
  location = var.compute_region
  service  = google_cloud_run_service.ingestion_service.name
  role     = "roles/run.invoker"
  member   = format("serviceAccount:%s", google_service_account.ingestion_invoker_identity.email)
}

# Give the ingestion runner service account permissions it needs (e.g. GCS bucket access). Add to the permissions list
# here if the ingestion runner needs access to other GCP resources.
resource "google_project_iam_custom_role" "ingestion_runner_role" {
  role_id     = var.ingestion_runner_role_id
  title       = "Ingestion Runner"
  description = "Allows data upload to GCS bucket and pubsub publish to notify completion"
  permissions = ["storage.objects.create", "storage.objects.delete", "storage.objects.get", "storage.objects.list",
  "storage.objects.update", "storage.buckets.get", "pubsub.topics.publish"]
}

resource "google_project_iam_member" "ingestion_runner_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.ingestion_runner_role.id
  member  = format("serviceAccount:%s", google_service_account.ingestion_runner_identity.email)
}

# Service account used to invoke the cloud run service through the push subscription.
resource "google_service_account" "gcs_to_bq_invoker_identity" {
  # The account id that is used to generate the service account email. Must be 6-30 characters long and
  # match the regex [a-z]([-a-z0-9]*[a-z0-9]).
  account_id = var.gcs_to_bq_invoker_identity_id
}

# Service account whose identity is used when running the GCS-to-BQ service.
resource "google_service_account" "gcs_to_bq_runner_identity" {
  # The account id that is used to generate the service account email. Must be 6-30 characters long and
  # match the regex [a-z]([-a-z0-9]*[a-z0-9]).
  account_id = var.gcs_to_bq_runner_identity_id
}

# Give the GCS-to-BQ invoker service account the existing invoker role so that it can call the GCS-to-BQ service.
resource "google_cloud_run_service_iam_member" "gcs_to_bq_invoker_binding" {
  location = var.compute_region
  service  = google_cloud_run_service.gcs_to_bq_service.name
  role     = "roles/run.invoker"
  member   = format("serviceAccount:%s", google_service_account.gcs_to_bq_invoker_identity.email)
}

# Give the GCS-to-BQ runner service account permissions it needs (e.g. GCS bucket access). Add to the permissions list
# here if the GCS-to-BQ runner needs access to other GCP resources.
resource "google_project_iam_custom_role" "gcs_to_bq_runner_role" {
  role_id     = var.gcs_to_bq_runner_role_id
  title       = "GCS-to-BQ Runner"
  description = "Allows reading data from GCS bucket and writing and reading BQ datasets."
  permissions = ["storage.objects.get", "storage.objects.list", "storage.buckets.get",
                 "bigquery.datasets.get", "bigquery.tables.create", "bigquery.tables.delete",
                 "bigquery.tables.get", "bigquery.tables.list", "bigquery.tables.update",
                 "bigquery.tables.updateData", "bigquery.jobs.create"]
}

resource "google_project_iam_member" "gcs_to_bq_runner_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.gcs_to_bq_runner_role.id
  member  = format("serviceAccount:%s", google_service_account.gcs_to_bq_runner_identity.email)
}
/* 
 * [END] Service Account Setup 
 */

/*
 * [BEGIN] Cloud Run Setup
 */

# Create a Pub/Sub topic to trigger the GCS-to-BQ service.
resource "google_pubsub_topic" "notify_data_ingested" {
  name = var.notify_data_ingested_topic
}

# Push subscription for upload_to_gcs topic that invokes the run service.
resource "google_pubsub_subscription" "ingestion_subscription" {
  name  = var.ingestion_subscription_name
  topic = google_pubsub_topic.upload_to_gcs.name

  ack_deadline_seconds = 20

  push_config {
    # Due to Terraform config language restrictions, index the first status element in a list of one.
    push_endpoint = google_cloud_run_service.ingestion_service.status.0.url
    oidc_token {
      service_account_email = google_service_account.ingestion_invoker_identity.email
    }
  }
}

# Cloud Run service for uploading data to gcs.
resource "google_cloud_run_service" "ingestion_service" {
  name     = var.run_ingestion_service_name
  location = var.compute_region
  project  = var.project_id

  template {
    spec {
      containers {
        image = var.run_ingestion_image_path
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "NOTIFY_DATA_INGESTED_TOPIC"
          value = var.notify_data_ingested_topic
        }
      }
      service_account_name = google_service_account.ingestion_runner_identity.email
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
  autogenerate_revision_name = true
}

# Push subscription for notify_data_ingested topic that invokes the run service.
resource "google_pubsub_subscription" "notify_data_ingested_subscription" {
  name  = var.notify_data_ingested_subscription_name
  topic = google_pubsub_topic.notify_data_ingested.name

  ack_deadline_seconds = 20

  push_config {
    # Due to Terraform config language restrictions, index the first status element in a list of one.
    push_endpoint = google_cloud_run_service.gcs_to_bq_service.status.0.url
    oidc_token {
      service_account_email = google_service_account.gcs_to_bq_invoker_identity.email
    }
  }
}

# Cloud Run service for loading GCS buckets into Bigquery.
resource "google_cloud_run_service" "gcs_to_bq_service" {
  name     = var.run_gcs_to_bq_service_name
  location = var.compute_region
  project  = var.project_id

  template {
    spec {
      containers {
        image = var.run_gcs_to_bq_image_path
        env {
          # Name of BQ dataset that we will add the tables to. This currently points to the main BQ dataset.
          name  = "DATASET_NAME"
          value = var.bq_dataset_name
        }
      }
      service_account_name = google_service_account.gcs_to_bq_runner_identity.email
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
  autogenerate_revision_name = true
}
/* 
 * [END] Cloud Run Setup
 */

/*
 * [BEGIN] Cloud Scheduler Setup
 */

# Create a Pub/Sub topic to trigger data_ingestion_to_gcs.
resource "google_pubsub_topic" "upload_to_gcs" {
  name = var.upload_to_gcs_topic_name
}

# Create a Cloud Scheduler task to trigger the upload_to_gcs Pub/Sub event for household income data.
resource "google_cloud_scheduler_job" "household_income_scheduler" {
  name        = var.household_income_scheduler_name
  description = "Triggers uploading household income data from SAIPE to GCS every Thursday at 8:10 ET."
  time_zone   = "America/New_York"
  schedule    = "10 8 * * 5"

  pubsub_target {
    topic_name = google_pubsub_topic.upload_to_gcs.id
    data = base64encode(jsonencode({
      "id" : "HOUSEHOLD_INCOME",
      "url" : "https://api.census.gov/data/timeseries/poverty/saipe",
      "gcs_bucket" : google_storage_bucket.gcs_data_ingestion_landing_bucket.name,
      "filename" : "SAIPE"
    }))
  }
}

# Create a Cloud Scheduler task to trigger the upload_to_gcs Pub/Sub event for state names data
resource "google_cloud_scheduler_job" "state_names_scheduler" {
  name        = var.state_names_scheduler_name
  description = "Triggers uploading state names data from the census API to GCS every Thursday at 8:10 ET."
  time_zone   = "America/New_York"
  schedule    = "10 8 * * 5"

  pubsub_target {
    topic_name = google_pubsub_topic.upload_to_gcs.id
    data = base64encode(jsonencode({
      "id" : "STATE_NAMES",
      "url" : "https://api.census.gov/data/2010/dec/sf1",
      "gcs_bucket" : google_storage_bucket.gcs_data_ingestion_landing_bucket.name,
      "filename" : "state_names.json"
    }))
  }
}

# Create a Cloud Scheduler task to trigger the upload_to_gcs Pub/Sub event for county names data
resource "google_cloud_scheduler_job" "county_names_scheduler" {
  name        = var.county_names_scheduler_name
  description = "Triggers uploading county names data from the census API to GCS every Thursday at 8:10 ET."
  time_zone   = "America/New_York"
  schedule    = "10 8 * * 5"

  pubsub_target {
    topic_name = google_pubsub_topic.upload_to_gcs.id
    data = base64encode(jsonencode({
      "id" : "COUNTY_NAMES",
      "url" : "https://api.census.gov/data/2010/dec/sf1",
      "gcs_bucket" : google_storage_bucket.gcs_data_ingestion_landing_bucket.name,
      "filename" : "county_names.json"
    }))
  }
}

# Create a Cloud Scheduler task to trigger the upload_to_gcs Pub/Sub event for population by race data
resource "google_cloud_scheduler_job" "population_by_race_scheduler" {
  name        = var.population_by_race_scheduler_name
  description = "Triggers uploading population by race data from the census API to GCS every Thursday at 8:10 ET."
  time_zone   = "America/New_York"
  schedule    = "10 8 * * 5"

  pubsub_target {
    topic_name = google_pubsub_topic.upload_to_gcs.id
    data = base64encode(jsonencode({
      "id" : "POPULATION_BY_RACE",
      # TODO: figure out how to detect the latest year for this data.
      "url" : "https://api.census.gov/data/2018/acs/acs5/profile",
      "gcs_bucket" : google_storage_bucket.gcs_data_ingestion_landing_bucket.name,
      "filename" : "population_by_race.json"
    }))
  }
}

# Create a Cloud Scheduler task to trigger the upload_to_gcs Pub/Sub event for county adjacency data
resource "google_cloud_scheduler_job" "county_adjacency_scheduler" {
  name        = var.county_adjacency_scheduler_name
  description = "Triggers uploading county adjacency data from the census API to GCS every Thursday at 8:10 ET."
  time_zone   = "America/New_York"
  schedule    = "10 8 * * 5"

  pubsub_target {
    topic_name = google_pubsub_topic.upload_to_gcs.id
    data = base64encode(jsonencode({
      "id" : "COUNTY_ADJACENCY",
      # Note: this is from the National Bureau of Economic Research, which is a
      # private non-profit. The official data comes from the Census Bureau
      # directly, but the file they published had formatting issues that caused
      # issues when trying to decode the data from cloud functions. It may be a
      # good idea to try to migrate to the official source. At the time of
      # writing the data is identical.
      "url" : "https://data.nber.org/census/geo/county-adjacency/2010/county_adjacency2010.csv",
      "gcs_bucket" : google_storage_bucket.gcs_data_ingestion_landing_bucket.name,
      "filename" : "county_adjacency.csv"
    }))
  }
}

# Create a Cloud Scheduler task to trigger the Pub/Sub event
resource "google_cloud_scheduler_job" "primary_care_scheduler" {
  name                    = var.primary_care_access_scheduler_name
  description             = "Triggers uploading primary care access to GCS every Thursday at 8:10 ET."
  time_zone               = "America/New_York"
  schedule                = "10 8 * * 5"

  pubsub_target {
    topic_name            = google_pubsub_topic.upload_to_gcs.id
    data                  = base64encode(jsonencode({
                              "id":"PRIMARY_CARE_ACCESS",
                              "gcs_bucket": google_storage_bucket.gcs_data_ingestion_landing_bucket.name,
                              "fileprefix":"primary-care"
                            }))
  }
}
/* [END] Cloud Scheduler Setup */
