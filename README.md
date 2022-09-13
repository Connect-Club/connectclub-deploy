# Connect.Club demo launch

This instruction covers how to create demo launch of Connect.Club application. First of all clone this repository and change curent directory to it.

## 1. Deploy backend

Choose one of the proposed deployment options

- Local launch on Docker through Docker Compose
  Prerequisites: [Docker Desktop](https://www.docker.com/products/docker-desktop/)

  Command:
  ```
  export DOCKER_HOST_ADDRESS=YOUR-IP-IN-LOCAL-NETWORK && docker-compose up -d
  ```


- Cloud launch on Google Cloud Platform through Terraform
  Prerequisites: MacOS/Linux, [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli), [Packer](https://learn.hashicorp.com/tutorials/packer/get-started-install-cli)

  Create file terraform.tfvars with variables from main.tf (or specify all variables with -var command line option)

  Command:
  ```
  terraform init && terraform apply
  ```

  Sometimes timeout error can accour. In this case try to repeat the command ```terraform apply```.
  
  For connecting to API's database you have to find k8s load balancer's ip (database itself does not have public ip and access to it only possible through k8s service with the name ```primary-db```). The credentials you can find in file terraform.tfstate in resource google_sql_user.primary_db_user.

## 2. Build and run mobile application

Clone mobile application [repository](https://github.com/Connect-Club/connectclub-mobile) and change current directory to it. Edit file ```src/api/api.ts```. Change api endpoint address in function ```getEndpoint``` for testing environment. For local backend it has to be ```http://DOCKER_HOST_ADDRESS:8092/api```, for cloud - ```https://CLOUD-ADDRESS/api```. Replace DOCKER_HOST_ADDRESS or CLOUD-ADDRESS wite appropriate values. Then set launch environment with command ```node ./scripts/init.js testing qa```. After that you have to build and run mobile application. Instruction in [the repository](https://github.com/Connect-Club/connectclub-mobile) can help you but this is not a trivial process. So you may need help from a mobile developer.

## 3. Simple use case

At this point mobile application is up and running and showing you a screen where you can choose how you want to sign up to Connect.Club. Choose phone number, because crypto wallet does not work in this demo. Type random phone number and press Next. Wait about 10 seconds and type test code 1111. On the next screens fill down all necessary information. When application ask you to wait for invite from other user, you have to do it manually in database. In case of local launch just use this command:
```
docker exec connectclub-deploy-primary-db-1 psql -c "update users set state='verified' where state='waiting_list'"
```
For cloud launch you have to connect to the database with your preferrable client and run this SQL script:
```
update users set state='verified' where state='waiting_list'
```
Then press Check in mobile application and you will be a registered user in Connect.Club demo. Now you are able to create rooms with other users. Just register them and Start a room together.
