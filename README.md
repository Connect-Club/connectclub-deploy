# Local launch on Docker through Docker Compose
Prerequisites: Docker Desktop(https://www.docker.com/products/docker-desktop/)

Command: export DOCKER_HOST_ADDRESS=YOUR-IP-IN-LOCAL-NETWORK && docker-compose up -d

Verify all users in waiting list: docker exec connectclub-deploy_primary-db_1 psql -c "update users set state='verified' where state='waiting_list'"

Assign admin role to user: docker exec connectclub-deploy_primary-db_1 psql -c "insert into users_roles(id, user_id, role) values (1, (select id from users where username='REPLACE-WITH-SUITABLE-USERNAME'),'admin')"



# Cloud launch on Google Cloud Platform through Terraform
Prerequisites: Terraform(https://learn.hashicorp.com/tutorials/terraform/install-cli), Packer(https://learn.hashicorp.com/tutorials/packer/get-started-install-cli)

Create file terraform.tfvars with variables from main.tf (or specify all variables with -var command line option)

Command: terraform init && terraform apply

Sometimes timeout error can accour. In this case try to repeat command 'terraform apply'.

For connecting to API's database you have to find k8s load balancer's ip (database itself does not have public ip and access to it only possible through k8s service with name primary-db). The credentials you can find in file terraform.tfstate in resource google_sql_user.primary_db_user.
For verifying user and assigning particular role do the similar things in docker compose section, but with database in the cloud.
