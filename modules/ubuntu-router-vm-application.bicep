targetScope = 'resourceGroup'

@description('Azure region for the Azure Compute Gallery and VM Application resources.')
param location string = resourceGroup().location

@description('Azure Compute Gallery name used to publish the Ubuntu router VM Application.')
param galleryName string = 'galHybridDns'

@description('Gallery application name for the Ubuntu SD-WAN/router appliance package.')
param applicationName string = 'ubuntu-sdwan-router'

@description('Gallery application version. Azure VM Application versions must use semantic version format such as 1.0.0.')
param applicationVersionName string = '1.0.0'

@description('HTTPS URI for the zipped VM Application package artifact. Leave empty to create the gallery application without publishing a version.')
param packageFileUri string = ''

@description('Target region replica count for the VM Application version.')
param replicaCount int = 1

@description('Storage account type used for VM Application version replicas.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
])
param replicaStorageAccountType string = 'Standard_LRS'

@description('Tags applied to deployed resources.')
param tags object = {}

var shouldPublishApplicationVersion = !empty(packageFileUri)

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: galleryName
  location: location
  properties: {
    description: 'Compute Gallery for hybrid DNS lab VM applications.'
  }
  tags: tags
}

resource application 'Microsoft.Compute/galleries/applications@2022-08-03' = {
  parent: gallery
  name: applicationName
  location: location
  properties: {
    supportedOSType: 'Linux'
    description: 'Ubuntu SD-WAN/router-style appliance bootstrap package with FRR, WireGuard, strongSwan, and forwarding defaults.'
  }
}

resource applicationVersion 'Microsoft.Compute/galleries/applications/versions@2022-08-03' = if (shouldPublishApplicationVersion) {
  parent: application
  name: applicationVersionName
  location: location
  properties: {
    publishingProfile: {
      source: {
        mediaLink: packageFileUri
      }
      manageActions: {
        install: 'bash install.sh'
        remove: 'bash remove.sh'
        update: 'bash update.sh'
      }
      targetRegions: [
        {
          name: location
          regionalReplicaCount: replicaCount
          storageAccountType: replicaStorageAccountType
        }
      ]
    }
  }
}

output galleryResourceId string = gallery.id
output applicationResourceId string = application.id
output applicationVersionResourceId string = shouldPublishApplicationVersion ? applicationVersion.id : ''
