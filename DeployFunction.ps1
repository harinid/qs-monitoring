﻿#script creates an azure function that serves as a monitor for Azure Database for PostgreSQL Query Store
#sign in to Azure
#Login-AzureRmAccount

#find out the current selected subscription
#Get-AzureRmSubscription | Select Name, SubscriptionId

Param(
   [Parameter(Mandatory= $true, HelpMessage="Enter resource group name for your monitor")]
   [ValidateNotNullorEmpty()]
   [string] $resourceGroupName,
   [Parameter(Mandatory= $true, HelpMessage="Enter the region for your monitor")]
   [ValidateNotNullorEmpty()]
   [string] $resourceGroupLocation,
   [Parameter(Mandatory= $true, HelpMessage="Enter the unique name for your monitor")]
   [ValidateNotNullorEmpty()]
   [string] $functionAppName,
   [Parameter(Mandatory= $true, HelpMessage="Enter either an existing keyvault's name or provide a new name to create a new keyvault to secure your secrets that you'll use for your monitor")]
   [ValidateNotNullorEmpty()]
   [string] $keyVaultName,
   [Parameter(Mandatory= $true, HelpMessage="Enter the email account or accounts separated by ';' that the alerts should be sent to")]
   [ValidateNotNullorEmpty()]
   [string] $mailTo,
   [Parameter(Mandatory= $true, HelpMessage="Enter the email account that the alerts should be sent from")]
   [ValidateNotNullorEmpty()]
   [string] $senderAccount,
   [Parameter(Mandatory= $true, HelpMessage="Enter the smtp server form the senderAccount that you just entered. An example for a live.com or outlook.com account would be smtp.office365.com")]
   [ValidateNotNullorEmpty()]
   [string] $smtpServer,
   [Parameter(Mandatory= $false, HelpMessage="Enter subscription name for your monitor")]
   [ValidateNotNullorEmpty()]
   [string] $subscriptionName="YourDefaultSubscriptionName",
   [Parameter(Mandatory= $false, HelpMessage="Enter the secret name that you will store your database connection string in your keyvault")]
   [ValidateNotNullorEmpty()]
   [string] $keyVaultConnectionStringSecretName="pgConnectionString",
   [Parameter(Mandatory= $false, HelpMessage="Enter the secret name that you will store your sender email account's password in your keyvault")]
   [ValidateNotNullorEmpty()]
   [string] $keyVaultSenderAccountSecretName="senderSecret",
   [Parameter(Mandatory= $true, HelpMessage="Enter the full connection string to the database that you are connecting to in order to monitor. This value will be passed to keyvault as SecureString and will be stored encrypted")]
   [ValidateNotNullorEmpty()]
   [string] $databaseConnectionStringValue,
   [Parameter(Mandatory= $true, HelpMessage="Enter the password for the email account that will send the alert emails. This value will be passed to keyvault as SecureString and will be stored encrypted")]
   [ValidateNotNullorEmpty()]
   [string] $senderAccountsPasswordValue
)

    #assign a unique name for deployment
    $stamp = Get-Date -Format yyyyMMddHHmmsss
    $deploymentName= "$functionAppName$stamp"
    $mailToSetting="MAIL_TO=$mailTo"
    $smtpServerSetting="SMTP_SERVER=$smtpServer"
    $connectionStringSecretNameSetting="CONNECTION_STRING_SECRET_NAME=$keyVaultConnectionStringSecretName"
    $senderAccountSecretNameSetting="SENDER_ACCOUNT_SECRET_NAME=$keyVaultSenderAccountSecretName"
    $senderAccountSetting="SENDER_ACCOUNT=$senderAccount"

       
    $logFilePath = "$PSScriptRoot\logs\$deploymentName.txt"
    $templateFilePath="$PSScriptRoot\arm\azuredeploy.json"
    $parameterFilePath="$PSScriptRoot\arm\azuredeploy.parameters.json"


    function log($string, $color)
    {
       $logEntry = "$($(Get-Date).ToString()) :    $string"
       if ($Color -eq $null) {$color = "white"}
       write-host $logEntry -foregroundcolor $color
       $logEntry | out-file -Filepath $logFilePath -append
    }

    # select a particular subscription
    Select-AzureRmSubscription -SubscriptionName $subscriptionName

    #get acceptable locations and validate location parameter
    $locations = Get-AzureRmLocation|Select Location
    if($locations.Location -notcontains $resourceGroupLocation)
    {
        log "---> Location provided is not a valid location. Please try again.\_(ツ)_/" red
        exit
    }

    #see if the resource group exists; if not, create it
    $rgResource=Get-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation -ErrorVariable rgNotPresent -ErrorAction SilentlyContinue
    if($rgNotPresent)
    {
        log "ResourceGroup does not exist;creating $resourceGroupName in $resourceGroupLocation region" yellow
        $rgResource=New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation -ErrorAction Stop
        log 'ResourceGroup successfully created' green
    }
    else
    {log "$($rgResource.ResourceId) already exists" green}

    log "---> Getting the uri for the keyvault specified" yellow
    $kvResource = Get-AzureRmKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroupName
    if($kvResource -eq $null)
    {
        log "---> Keyvault does not exist. Creating a new keyvault" yellow
        $kvResource = New-AzureRmKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroupName -Location $resourceGroupLocation -ErrorAction Stop
    }
    log "---> The keyvault is at $($kvResource.VaultUri)" green
    #function app setting that contains your keyvault uri
    $keyVaultUriSetting="KeyVaultUri=$($kvResource.VaultUri)"

    #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    #+++++++++++++++++ SET VALUES AS APPROPRIATE ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    #function's app settings for monitor's run interval, queries for 
    #alert condition and the supporting data when alert condition is met
    #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    $cronIntervalSetting="CronTimerInterval=0 */1 * * * *"
    $ifQuerySetting="SENDMAILIF_QUERYRETURNSRESULTS=select * from query_store.qs_view where mean_time > 5000 and start_time >= now() - interval '15 minutes'"
    $thenQueriesSetting="LIST_OF_QUERIESWITHSUPPORTINGDATA={""""LONG_QUERY_PSQL_STRING"""":""""select datname as Database, pid as Process_ID, usename as Username, query,client_hostname,state, now() - query_start as Query_Duration, now() - backend_start as Session_Duration from pg_stat_activity where age(clock_timestamp(),query_start) > interval '5 minutes' and state like 'active' and usename not like 'postgres' order by 1 desc;"""",""""LIST_OF_PROCESSES"""":""""select now()-query_start as Running_Since,pid,client_hostname,client_addr, usename, state, left(query,60) as query_text from pg_stat_activity;""""}"
    #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    #Note that you can always update these after deployment. If you are #directly updating queries, double quotes '"' can be exist as is
    #i.e instead of """"LONG_QUERY_PSQL_STRING"""" you can just enter "LONG_QUERY_PSQL_STRING"
    #++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    
    #deploy function and update the settings
    #use the following commented line instead of the current assignment if you want to use a json file for the parameters instead
    #$parameters = $parameterFilePath
    $parameters = "{""appName"":{""value"":""$functionAppName""}}"
    $deployment = az group deployment create --name $deploymentName --resource-group $resourceGroupName --template-file $templateFilePath --parameters $parameters --verbose 
    log "---> Deploying monitoring function via deployment $deploymentName" yellow

    $functionAppDeployment = az functionapp deployment source config-zip -g $resourceGroupName -n $functionAppName --src "$PSScriptRoot\PollPg\zip\Alert.zip" --verbose | ConvertFrom-Json
    log "---> Updating configuration settings. You can check the latest deployment status and logs from $($functionAppDeployment.url)" yellow

    $functionAppAppSettings = az functionapp config appsettings set --resource-group $resourceGroupName --name $functionAppName  --settings $cronIntervalSetting $ifQuerySetting $thenQueriesSetting $keyVaultUriSetting $mailToSetting $smtpServerSetting $connectionStringSecretNameSetting $senderAccountSecretNameSetting $senderAccountSetting 

    log "---> App configuration settings updated" green

    log "---> Getting the system assigned identity for the function" yellow

    #get principal id of function app. assign option will create if no system assigned identity exists or return existing one
    $functionAppIdentity = az functionapp identity assign --name $functionAppName --resource-group  $resourceGroupName | ConvertFrom-Json
    $principalId = $functionAppIdentity.principalId
    log "---> App identity assigned for principal $principalId" green

    #ensure that keyvault properly propagated before setting up the necessary policies and secrets
    do
    {
        log "---> Polling keyvault $keyVaultName" yellow
        $kvShowResult = az keyvault show --name $keyVaultName
    } while ($kvShowResult -eq $null)

    log "---> Keyvault is ready to use" green
    log "---> Adding the system assigned identity for the function to the keyvault to set the appropriate policy" yellow
    $keyVaultPolicyUpdate = az keyvault set-policy --name $keyVaultName --object-id $principalId --secret-permissions get


    log "---> Setting up the required keyvault secrets" yellow

    #adding keyvault secrets as outlined above with temporary values. you will need to update the values to the actual ones as appropriate
    #sample connection string to store
    # Server=YourServerName.postgres.database.azure.com;Database=azure_sys;Port=5432;User Id=YourUser@YourServerName;Password=YourPassword;SslMode=Require;       
    $secretUpdateResult = az keyvault secret set --vault-name $keyVaultName --name $keyVaultConnectionstringSecretName --value $databaseConnectionStringValue
    log "---> A new version for $keyVaultConnectionstringSecretName is successfully created" green

    $secretUpdateResult = az keyvault secret set --vault-name $keyVaultName --name $keyVaultSenderAccountSecretName --value $senderAccountsPasswordValue
    log "---> A new version for $keyVaultSenderAccountSecretName is successfully created" green

    log "---> Script completed. You can go to your function to check or update app settings and validate that monitor is running as expected" green
    log "---> Log is available at $logFilePath"