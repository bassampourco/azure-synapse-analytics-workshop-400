Remove-Module solliance-synapse-automation
Import-Module ".\artifacts\environment-setup\solliance-synapse-automation"

$InformationPreference = "Continue"

# These need to be run only if the Az modules are not yet installed
# Install-Module -Name Az -AllowClobber -Scope CurrentUser
# Install-Module -Name Az.CosmosDB -AllowClobber -Scope CurrentUser
# Import-Module Az.CosmosDB

#
# TODO: Keep all required configuration in C:\LabFiles\AzureCreds.ps1 file
. C:\LabFiles\AzureCreds.ps1

$userName = $AzureUserName                # READ FROM FILE
$password = $AzurePassword                # READ FROM FILE
$clientId = $TokenGeneratorClientId       # READ FROM FILE
$sqlPassword = $AzureSQLPassword          # READ FROM FILE

$securePassword = $password | ConvertTo-SecureString -AsPlainText -Force
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $userName, $SecurePassword

Connect-AzAccount -Credential $cred | Out-Null

$resourceGroupName = (Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -like "*L400*" }).ResourceGroupName
$uniqueId =  (Get-AzResourceGroup -Name $resourceGroupName).Tags["DeploymentId"]
$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id

$templatesPath = ".\artifacts\environment-setup\templates"
$datasetsPath = ".\artifacts\environment-setup\datasets"
$pipelinesPath = ".\artifacts\environment-setup\pipelines"
$sqlScriptsPath = ".\artifacts\environment-setup\sql"
$workspaceName = "asaworkspace$($uniqueId)"
$cosmosDbAccountName = "asacosmosdb$($uniqueId)"
$cosmosDbDatabase = "CustomerProfile"
$cosmosDbContainer = "OnlineUserProfile01"
$dataLakeAccountName = "asadatalake$($uniqueId)"
$blobStorageAccountName = "asastore$($uniqueId)"
$keyVaultName = "asakeyvault$($uniqueId)"
$keyVaultSQLUserSecretName = "SQL-USER-ASA"
$sqlPoolName = "SQLPool01"
$integrationRuntimeName = "AzureIntegrationRuntime01"
$sparkPoolName = "SparkPool01"
$amlWorkspaceName = "amlworkspace$($uniqueId)"


$ropcBodyCore = "client_id=$($clientId)&username=$($userName)&password=$($password)&grant_type=password"
$global:ropcBodySynapse = "$($ropcBodyCore)&scope=https://dev.azuresynapse.net/.default"
$global:ropcBodyManagement = "$($ropcBodyCore)&scope=https://management.azure.com/.default"
$global:ropcBodySynapseSQL = "$($ropcBodyCore)&scope=https://sql.azuresynapse.net/.default"

$global:synapseToken = ""
$global:synapseSQLToken = ""
$global:managementToken = ""

$global:tokenTimes = [ordered]@{
        Synapse = (Get-Date -Year 1)
        SynapseSQL = (Get-Date -Year 1)
        Management = (Get-Date -Year 1)
}

$kvSecretName = "PipelineSecret"
$kvSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $kvSecretName
if ($kvSecret) {
        Remove-AzKeyVaultSecret -VaultName $keyVaultName -Name $kvSecretName -Force
}

$lockName = "DeleteLock"
$rgLock = Get-AzResourceLock -LockName $lockName -ResourceGroupName $resourceGroupName
if ($rgLock) {
        Remove-AzResourceLock -LockId $rgLock.LockId -Force
}

$largeIntegrationRuntimeName = "AzureLargeComputeOptimizedIntegrationRuntime"
Write-Information "Removing $($largeIntegrationRuntimeName) integration runtime..."
$result = Get-IntegrationRuntime -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -Name $largeIntegrationRuntimeName
if ($result) {
        $result = Delete-IntegrationRuntime -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -Name $largeIntegrationRuntimeName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

if ($rgLock) {
        New-AzResourceLock -LockName $lockName -LockLevel CanNotDelete -ResourceGroupName $resourceGroupName -Force
}

Write-Information "Removing workspace artifacts"

$asaArtifacts = [ordered] @{

        "ASAL400 - Lab 2 - Write Campaign Analytics to ASA" = "pipelines"
        "ASAL400 - Lab 2 - Write User Profile Data to ASA" = "pipelines"
        "ASAL400 - Copy December Sales" = "pipelines"
}

$asaArtifacts2 = [ordered]@{

        "ASAL400 - Lab 2 - Write Campaign Analytics to ASA" = "dataflows"
        "ASAL400 - Lab 2 - Write User Profile Data to ASA" = "dataflows"
        "asal400_customerprofile_cosmosdb" = "datasets"
        "asal400_sales_adlsgen2" = "datasets"
        "asal400_ecommerce_userprofiles_source" = "datasets"
        "asal400_december_sales" = "datasets"
        "asal400_saleheap_asa" = "datasets"
        "asal400_campaign_analytics_source" = "datasets"
        "asal400_wwi_campaign_analytics_asa" = "datasets"
        "asal400_wwi_userproductreviews_asa" = "datasets"
        "asal400_wwi_usertopproductpurchases_asa" = "datasets"
        "asacosmosdb01" = "linkedServices"
}

foreach ($asaArtifactName in $asaArtifacts.Keys) {
        Write-Information "Deleting $($asaArtifactName) in $($asaArtifacts[$asaArtifactName])"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category $asaArtifacts[$asaArtifactName] -Name $asaArtifactName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

foreach ($asaArtifactName in $asaArtifacts2.Keys) {
        Write-Information "Deleting $($asaArtifactName) in $($asaArtifacts2[$asaArtifactName])"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category $asaArtifacts2[$asaArtifactName] -Name $asaArtifactName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

#
# =============== COSMOS DB IMPORT  ====================
#                         


Write-Information "Rebuild Cosmos DB container $($cosmosDbContainer) in $($cosmosDbDatabase) database"

$container = Get-AzCosmosDBSqlContainer `
        -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer

if ($container) {

        $lockName = "DeleteLock"
        $rgLock = Get-AzResourceLock -LockName $lockName -ResourceGroupName $resourceGroupName
        if ($rgLock) {
                Remove-AzResourceLock -LockId $rgLock.LockId -Force
        }

        Write-Information "Deleting $($cosmosDbContainer) from $($cosmosDbDatabase) Cosmos DB database"

        Remove-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
                -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
                -Name $cosmosDbContainer

        if ($rgLock) {
                New-AzResourceLock -LockName $lockName -LockLevel CanNotDelete -ResourceGroupName $resourceGroupName -Force
        }
}

Write-Information "Creating $($cosmosDbContainer) in $($cosmosDbDatabase) Cosmos DB database"

Set-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer -Throughput 10000 `
        -PartitionKeyKind $container.Resource.PartitionKey.Kind `
        -PartitionKeyPath $container.Resource.PartitionKey.Paths

$name = "wwi02_online_user_profiles_01_adal"
Write-Information "Create dataset $($name)"
$result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $name -LinkedServiceName $dataLakeAccountName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Cosmos DB linked service $($cosmosDbAccountName)"
$cosmosDbAccountKey = List-CosmosDBKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $cosmosDbAccountName
$result = Create-CosmosDBLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $cosmosDbAccountName -Database $cosmosDbDatabase -Key $cosmosDbAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$name = "customer_profile_cosmosdb"
Write-Information "Create dataset $($name)"
$result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $name -LinkedServiceName $cosmosDbAccountName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$name = "Setup - Import User Profile Data into Cosmos DB"
$fileName = "import_customer_profiles_into_cosmosdb"
Write-Information "Create pipeline $($name)"
$result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $name -FileName $fileName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Running pipeline $($name)"
$pipelineRunResult = Run-Pipeline -WorkspaceName $workspaceName -Name $name
$result = Wait-ForPipelineRun -WorkspaceName $workspaceName -RunId $pipelineRunResult.runId
$result

#
# =============== WAIT HERE FOR PIPELINE TO FINISH - TAKES ~8 MINUTES ====================
#                         
#                    COPY 100000 records to CosmosDB ==> SELECT VALUE COUNT(1) FROM C
#

$container = Get-AzCosmosDBSqlContainer `
        -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer

Write-Information "Scaling down $($cosmosDbContainer) from $($cosmosDbDatabase) Cosmos DB database to 400 RUs"

Set-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer -Throughput 400 `
        -PartitionKeyKind $container.Resource.PartitionKey.Kind `
        -PartitionKeyPath $container.Resource.PartitionKey.Paths

$name = "Setup - Import User Profile Data into Cosmos DB"
Write-Information "Delete pipeline $($name)"
$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "pipelines" -Name $name
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$name = "customer_profile_cosmosdb"
Write-Information "Delete dataset $($name)"
$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $name
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$name = "wwi02_online_user_profiles_01_adal"
Write-Information "Delete dataset $($name)"
$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $name
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

$name = $cosmosDbAccountName
Write-Information "Delete linked service $($name)"
$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "linkedServices" -Name $name
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId


#
# =============== SQL Pool import  ====================
#           

Write-Information "Start the $($sqlPoolName) SQL pool if needed."

$result = Get-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName
if ($result.properties.status -ne "Online") {
    Control-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Action resume
    Wait-ForSQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -TargetStatus Online
}

Write-Information "Cleanup SQL pool $($sqlPoolName)"

$params = @{}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "19-cleanup-sql-pool" -Parameters $params
$result

Write-Information "Reset result set caching for SQL pool $($sqlPoolName)"
$query = "ALTER DATABASE [$($sqlPoolName)] SET RESULT_SET_CACHING ON"
$result = Execute-SQLQuery -WorkspaceName $workspaceName -SQLPoolName "master" -SQLQuery $query

Write-Information "Create tables in the [wwi] schema in $($sqlPoolName)"

$params = @{}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "04-create-tables-in-wwi-schema" -Parameters $params
$result


Write-Information "Create data sets for data load in SQL pool $($sqlPoolName)"

$loadingDatasets = @{
        wwi02_date_adls = $dataLakeAccountName
        wwi02_product_adls = $dataLakeAccountName
        wwi02_sale_small_adls = $dataLakeAccountName
        wwi02_date_asa = $sqlPoolName.ToLower()
        wwi02_product_asa = $sqlPoolName.ToLower()
        wwi02_sale_small_asa = "$($sqlPoolName.ToLower())_highperf"
}

foreach ($dataset in $loadingDatasets.Keys) {
        Write-Information "Creating dataset $($dataset)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $dataset -LinkedServiceName $loadingDatasets[$dataset]
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

Write-Information "Create pipeline to load the SQL pool"

$params = @{
        BLOB_STORAGE_LINKED_SERVICE_NAME = $blobStorageAccountName
}
$loadingPipelineName = "Setup - Load SQL Pool"
$fileName = "load_sql_pool_from_data_lake"

Write-Information "Creating pipeline $($loadingPipelineName)"

$result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $loadingPipelineName -FileName $fileName -Parameters $params
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Running pipeline $($loadingPipelineName)"

$result = Run-Pipeline -WorkspaceName $workspaceName -Name $loadingPipelineName
$result = Wait-ForPipelineRun -WorkspaceName $workspaceName -RunId $result.runId
$result

Write-Information "Deleting pipeline $($loadingPipelineName)"

$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "pipelines" -Name $loadingPipelineName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

foreach ($dataset in $loadingDatasets.Keys) {
        Write-Information "Deleting dataset $($dataset)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $dataset
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

Write-Information "Create tables in wwi_perf schema in SQL pool $($sqlPoolName)"

$params = @{}
$scripts = [ordered]@{
        "07-create-wwi-perf-sale-heap" = "CTAS : Sale_Heap"
        "08-create-wwi-perf-sale-partition01" = "CTAS : Sale_Partition01"
        "09-create-wwi-perf-sale-partition02" = "CTAS : Sale_Partition02"
        "10-create-wwi-perf-sale-index" = "CTAS : Sale_Index"
        "11-create-wwi-perf-sale-hash-ordered" = "CTAS : Sale_Hash_Ordered"
}

foreach ($script in $scripts.Keys) {

        $refTime = (Get-Date).ToUniversalTime()
        Write-Information "Starting $($script) with label $($scripts[$script])"
        
        # initiate the script and wait until it finishes
        Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName $script -ForceReturn $true
        Wait-ForSQLQuery -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Label $scripts[$script] -ReferenceTime $refTime
}
