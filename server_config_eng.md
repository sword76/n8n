# Server Configurations for n8n on VPS

This document outlines the minimal and maximal server configurations for hosting the n8n architecture on a Virtual Private Server (VPS) from a single provider. The configurations are designed to handle a range of 100 to 1,000 daily unique users.

## 1. Assumptions

*   **User Activity:** A "daily unique user" is assumed to trigger a moderate number of workflow executions per day.
*   **Workflow Complexity:** Workflows are assumed to be of average complexity, without excessive data processing or long-running tasks.
*   **VPS Provider:** The configurations are based on typical VPS offerings (e.g., DigitalOcean, Linode, Vultr).
*   **Scalability:** The architecture allows for vertical scaling (increasing resources of a server) and horizontal scaling (adding more n8n servers).

## 2. Minimal Configuration (100 Daily Unique Users)

This configuration is suitable for a small user base with moderate activity.

| Component           | vCPUs | RAM   | Storage (SSD) | Notes                               |
| ------------------- | ----- | ----- | ------------- | ----------------------------------- |
| **Load Balancer**   | 1     | 1 GB  | 25 GB         | Can be a small VPS with NGINX.      |
| **n8n Server 1**    | 1     | 2 GB  | 50 GB         | Minimum recommended for n8n.        |
| **n8n Server 2**    | 1     | 2 GB  | 50 GB         | Provides redundancy.                |
| **PostgreSQL DB**   | 1     | 1 GB  | 50 GB         | Storage depends on execution logs.  |
| **Monitoring Stack**| 1     | 2 GB  | 50 GB         | Prometheus, Grafana, Loki, etc.     |
| **Total**           | **5** | **8 GB** | **225 GB**    |                                     |

## 3. Maximal Configuration (1,000 Daily Unique Users)

This configuration is designed for a larger user base with more frequent and potentially more complex workflow executions.

| Component           | vCPUs | RAM    | Storage (SSD) | Notes                                       |
| ------------------- | ----- | ------ | ------------- | ------------------------------------------- |
| **Load Balancer**   | 2     | 4 GB   | 80 GB         | To handle increased traffic.                |
| **n8n Server 1**    | 2     | 4 GB   | 160 GB        | More resources for workflow executions.     |
| **n8n Server 2**    | 2     | 4 GB   | 160 GB        | Provides redundancy and handles more load.  |
| **PostgreSQL DB**   | 2     | 4 GB   | 250 GB+       | Increased storage for logs and workflows.   |
| **Monitoring Stack**| 2     | 4 GB   | 100 GB        | Prometheus, Grafana, Loki, etc.     |
| **Total**           | **10**| **20 GB**| **750 GB+**   |                                             |

## 4. Scaling Considerations

*   **Database:** The PostgreSQL database can become a bottleneck. For the maximal configuration, consider using a managed database service from the VPS provider if available, as they often provide better performance and automated backups.
*   **Storage:** The storage for the PostgreSQL database is highly dependent on the number of workflow executions and the amount of data they log. Monitor storage usage and be prepared to increase it.
*   **Horizontal Scaling:** If the two n8n servers are not sufficient, you can add more n8n instances to the `docker-compose.yml` and `nginx.conf` to distribute the load further.
*   **Monitoring:** Implement monitoring for all servers to track CPU, RAM, and storage usage to identify bottlenecks and know when to scale.

## 5. Accessing Grafana

Grafana will be accessible at `http://<your_server_ip>:8181`. You can log in with the default credentials:
*   **Username:** admin
*   **Password:** grafana

You will be prompted to change the password after your first login.
