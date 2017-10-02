class ClusterCreationWorker
  include Sidekiq::Worker
  include DedicatedSidekiqQueue

  def perform(cluster_id)
    cluster = Gcp::Cluster.find_by_id(cluster_id)

    unless cluster
      return Rails.logger.error "Cluster object is not found; #{cluster_id}"
    end

    api_client =
      GoogleApi::CloudPlatform::Client.new(cluster.gcp_token, nil)

    operation = api_client.projects_zones_clusters_create(
        cluster.gcp_project_id,
        cluster.cluster_zone,
        cluster.cluster_name,
        cluster.cluster_size,
        machine_type: cluster.machine_type
      )

    if operation.is_a?(StandardError)
      return cluster.errored!("Failed to request to CloudPlatform; #{operation.message}")
    end
      
    unless operation.status == 'RUNNING' || operation.status == 'PENDING'
      return cluster.errored!("Operation status is unexpected; #{operation.status_message}")
    end

    operation_id = api_client.parse_operation_id(operation.self_link)

    unless operation_id
      return cluster.errored!('Can not find operation_id from self_link')
    end

    if cluster.creating!(operation_id)
      WaitForClusterCreationWorker.perform_in(
        WaitForClusterCreationWorker::INITIAL_INTERVAL,
        cluster.id
      )
    else
      return cluster.errored!("Failed to update cluster record; #{cluster.errors}")
    end
  end
end
