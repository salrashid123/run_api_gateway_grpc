
## GCP API Gateway with gRPC

Simple gRPC client/server for GCP API Gateway and Cloud Run:

`client` -> `(gRPC+auth)` -> `APIGateway` -> `(gRPC+auth)` -> `Cloud Run API Server`

other references:

- [gRPC Authentication with Cloud Run](https://github.com/salrashid123/cloud_run_grpc_auth)
- [gRPC Authentication with Google OpenID Connect tokens](https://github.com/salrashid123/grpc_google_id_tokens)
- [Endpoints v2: Configuring a gRPC service](https://cloud.google.com/endpoints/docs/grpc/grpc-service-config)
- [Google API Gateway](https://cloud.google.com/api-gateway/docs)

### Setup

Set environment variables

```bash
    export PROJECT_ID=`gcloud config get-value core/project`
    export PROJECT_NUMBER=`gcloud projects describe $PROJECT_ID --format='value(projectNumber)'`

    gcloud config set run/region us-central1
    gcloud config set run/platform managed
```

Optionally recompile proto file:

```bash
/usr/local/bin/protoc -I src/ \
 --include_imports --include_source_info \
 --descriptor_set_out=src/echo/echo.proto.pb \
 --go_out=plugins=grpc:src/ src/echo/echo.proto
```

### Build and deploy backend API server

Build & push backend server image

```bash
    docker build -t gcr.io/$PROJECT_ID/apiserver-grpc -f Dockerfile.server .
    docker push gcr.io/$PROJECT_ID/apiserver-grpc
```

```bash
gcloud run deploy apiserver-grpc \
  --image gcr.io/$PROJECT_ID/apiserver-grpc --no-allow-unauthenticated  -q


## the following enables a secondary application layer check for the authorization header and audience
## normally it isn't necessary to do this since this is done on the perimeter via GCP IAM
## but its my repo and i can do what i want
export RUN_URL=`gcloud run services describe apiserver-grpc --format='value(status.url)'`
echo $RUN_URL

gcloud beta run deploy apiserver-grpc  --min-instances 3   --max-instances 3 \
  --image gcr.io/$PROJECT_ID/apiserver-grpc --no-allow-unauthenticated \
  --args="--validateToken=true,--targetAudience=$RUN_URL"  -q  
```

Test direct access to backend.  

Now create a service account that will act as the 'client' to the gateway

```bash
gcloud iam service-accounts create gateway-client-sa  --display-name "Service Account for API-Gateway Client" 
gcloud iam service-accounts keys create api-client-sa.json --iam-account=gateway-client-sa@$PROJECT_ID.iam.gserviceaccount.com

export AUDIENCE=`gcloud beta run services describe apiserver-grpc --format="value(status.url)"`
export ADDRESS=`echo $AUDIENCE |  awk -F[/:] '{print $4}'`
echo $AUDIENCE
echo $ADDRESS

## allow this client to temp access the backend
## this step is just to test if the service is setup correctly
gcloud run services add-iam-policy-binding apiserver-grpc \
      --region us-central1  --platform=managed  \
      --member=serviceAccount:gateway-client-sa@$PROJECT_ID.iam.gserviceaccount.com \
      --role=roles/run.invoker

# wait about a min

$ go run src/grpc_client.go --address $ADDRESS:443 \
   --audience=$AUDIENCE \
   --servername $ADDRESS \
   --serviceAccount=api-client-sa.json

## if the step above works, +_revoke_ direct access (gateway-client-sa will eventually contact the gateway only)
gcloud run services remove-iam-policy-binding apiserver-grpc \
      --region us-central1  --platform=managed  \
      --member=serviceAccount:gateway-client-sa@$PROJECT_ID.iam.gserviceaccount.com \
      --role=roles/run.invoker
```

### Deploy Gateway

In the following step, we will create a service account that will eventually be used the "Gateways" Service Account

```bash
gcloud iam service-accounts create gateway-sa  --display-name "Service Account for API-Gateway" 

gcloud run services add-iam-policy-binding apiserver-grpc \
      --region us-central1  --platform=managed  \
      --member=serviceAccount:gateway-sa@$PROJECT_ID.iam.gserviceaccount.com \
      --role=roles/run.invoker
```

Now create the API 

```bash
gcloud beta api-gateway apis create grpc-api-1

gcloud beta api-gateway apis list
export MANAGED_SERVICE=`gcloud beta api-gateway apis describe grpc-api-1 --format="value(managedService)"`
echo $MANAGED_SERVICE
echo $AUDIENCE
echo $ADDRESS

gcloud endpoints configs list --service $MANAGED_SERVICE
```

Create the API.  

(This step is manual using curl until gcloud cli is updated)

```bash
export API_ID=grpc-api-1
export API_CONFIG_ID=grpc-config-1
export SOURCE_FILE=api_config.yaml
export PROTO_FILE=src/echo/echo.proto.pb


echo $MANAGED_SERVICE
echo $AUDIENCE
echo $ADDRESS
 
envsubst < "api_config.yaml.tmpl" > "api_config.yaml"


gcloud beta api-gateway api-configs create $API_CONFIG_ID --api=grpc-api-1 \
     --grpc-files=api_config.yaml,src/echo/echo.proto.pb  \
     --backend-auth-service-account=gateway-sa@$PROJECT_ID.iam.gserviceaccount.com 

```

wait about a 3 or 4 mins until its ACTIVE

```bash
$  gcloud beta api-gateway api-configs list
CONFIG_ID      API_ID      DISPLAY_NAME   SERVICE_CONFIG_ID            STATE   CREATE_TIME
grpc-config-1  grpc-api-1  grpc-config-1  grpc-config-1-05zcbixuegzsp  ACTIVE  2020-12-18T15:38:30
```

Create the gateway

```bash
gcloud beta api-gateway gateways create grpc-gateway-1 --location us-central-1 --api grpc-api-1 --api-config=grpc-config-1

export GATEWAY_HOST=`gcloud beta api-gateway gateways describe grpc-gateway-1 --location us-central1 --format='value(defaultHostname)'`
echo $GATEWAY_HOST
```

if you updated a config, you need to update the gateway to use it

```bash
gcloud alpha api-gateway gateways update grpc-gateway-1   --api=grpc-api-1 --api-config=grpc-config-2 --location=us-central1
```

## Finally invoke the API Gateway using the client

```bash
 go run src/grpc_client.go --address $GATEWAY_HOST:443 \
   --audience=grpcs://grpc-gateway-1 \
   --servername $GATEWAY_HOST \
   --serviceAccount=api-client-sa.json     
```

NOTE: the api gateway allows any Google Issued OIDC token through

For other options, see [Authentication Rules (google.api.AuthProvider)](https://cloud.google.com/endpoints/docs/grpc-service-config/reference/rpc/google.api#authprovider)

```yaml
authentication:
  providers:
  - id: google_id_token
    authorization_url: ''
    audiences: 'grpcs://grpc-gateway-1'
    issuer: 'https://accounts.google.com'
    jwks_uri: 'https://www.googleapis.com/oauth2/v1/certs'
  rules:
  - selector: "*"
    requirements:
      - provider_id: google_id_token
```


You should also notice the responses come back from different instances over one gRPC channel to the gateway.
That means the LB distributes each RPC to different Run backends.

```log
$ go run src/grpc_client.go --address $GATEWAY_HOST:443    --audience=grpcs://grpc-gateway-1    --servername $GATEWAY_HOST    --serviceAccount=../api-client-sa.json
2021/01/08 10:55:35 RPC Response: 0 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d01cf6178748e7d6b841411cafaef92c7fbc4e156aa5d745b718afb3a73cb3bfbacc8f6a7a2a35af203456aca9caafa38f125727c6bb23d"
2021/01/08 10:55:36 RPC Response: 1 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d3db44d5ea1d5796fc83a709cec8d3e560a16cf625a3f85b6a563ff2dbc5dbe7454157f18b63a4164fb6d2fe059fad36148cd446c8f53c951"
2021/01/08 10:55:37 RPC Response: 2 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d01cf6178748e7d6b841411cafaef92c7fbc4e156aa5d745b718afb3a73cb3bfbacc8f6a7a2a35af203456aca9caafa38f125727c6bb23d"
2021/01/08 10:55:38 RPC Response: 3 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02daaf8cec9ffe8412aed9dc8728a6e878e18f0e71b9576d959eb37b81ca0497a024602c3c6debf03d5b64ebc8210237a5fae57cf2192"
2021/01/08 10:55:39 RPC Response: 4 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d01cf6178748e7d6b841411cafaef92c7fbc4e156aa5d745b718afb3a73cb3bfbacc8f6a7a2a35af203456aca9caafa38f125727c6bb23d"
2021/01/08 10:55:40 RPC Response: 5 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d3db44d5ea1d5796fc83a709cec8d3e560a16cf625a3f85b6a563ff2dbc5dbe7454157f18b63a4164fb6d2fe059fad36148cd446c8f53c951"
2021/01/08 10:55:41 RPC Response: 6 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d01cf6178748e7d6b841411cafaef92c7fbc4e156aa5d745b718afb3a73cb3bfbacc8f6a7a2a35af203456aca9caafa38f125727c6bb23d"
2021/01/08 10:55:42 RPC Response: 7 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02daaf8cec9ffe8412aed9dc8728a6e878e18f0e71b9576d959eb37b81ca0497a024602c3c6debf03d5b64ebc8210237a5fae57cf2192"
2021/01/08 10:55:44 RPC Response: 8 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d01cf6178748e7d6b841411cafaef92c7fbc4e156aa5d745b718afb3a73cb3bfbacc8f6a7a2a35af203456aca9caafa38f125727c6bb23d"
2021/01/08 10:55:45 RPC Response: 9 message:"Hello unary RPC msg   from K_REVISION apiserver-grpc-00010-kow from instanceID 00bf4bf02d01cf6178748e7d6b841411cafaef92c7fbc4e156aa5d745b718afb3a73cb3bfbacc8f6a7a2a35af203456aca9caafa38f125727c6bb23d"
2021/01/08 10:55:45 Message: Msg1 Stream RPC msg from instanceID 00bf4bf02d3db44d5ea1d5796fc83a709cec8d3e560a16cf625a3f85b6a563ff2dbc5dbe7454157f18b63a4164fb6d2fe059fad36148cd446c8f53c951
2021/01/08 10:55:45 Message: Msg2 Stream RPC msg from instanceID 00bf4bf02d3db44d5ea1d5796fc83a709cec8d3e560a16cf625a3f85b6a563ff2dbc5dbe7454157f18b63a4164fb6d2fe059fad36148cd446c8f53c951
```
