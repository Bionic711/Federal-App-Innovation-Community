param Name string
param Location string
param Identity resourceIdentifier
param Subnet subnetIdentifier
param OutboundType string = 'userAssignedNATGateway'
param DisableOutboundNat bool = true
param KeyVault resourceIdentifier
param CurrentTime string = utcNow('yyyyMMdd-HHmmss')

param AgentSize string = 'Standard_D2S_v5' //Standard_DS2_v2

param SyslogLevels array
param SyslogFacilities array
@allowed([
  'Off'
  'Include'
  'Exclude'
])
param NamespaceFilteringModeForDataCollection string = 'Off'
param DataCollectionInterval string
param NamespacesForDataCollection array
param Streams array = [
  'Microsoft-ContainerInsights-Group-Default'
]
param EnableContainerLogV2 bool
param WorkspaceResourceId string


var dcrName = '${Name}-dcr'
var dataCollectionRuleId = resourceId(split(_aksMonitoringMsiDcr.?id, '/')[2] ?? subscription().subscriptionId, split(_aksMonitoringMsiDcr.?id, '/')[4] ?? resourceGroup().name, 'Microsoft.Insights/dataCollectionRules', dcrName)

#disable-next-line BCP081 // Valid API Version
resource _subnet 'Microsoft.Network/virtualNetworks/subnets@2024-03-01' existing = {
  name: '${Subnet.vNetName}/${Subnet.subnetName}'
  scope: resourceGroup(Subnet.?subscriptionId ?? subscription().subscriptionId, Subnet.?resourceGroupName ?? resourceGroup().name)
}

resource _identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: Identity.name
}

#disable-next-line BCP081 // Valid API Version
resource _aks 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  dependsOn: [
     _subnet
  ]
  name: Name
  location: Location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${_identity.id}': {}
    }
  }
  properties: {
    dnsPrefix: 'aksCluster'
    networkProfile: {
      networkPlugin: 'azure'
      outboundType: OutboundType
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: 2
        osType: 'Linux'
        vmSize: AgentSize
        mode: 'System'
        vnetSubnetID: resourceId(Subnet.?subscriptionId ?? subscription().subscriptionId, Subnet.?resourceGroupName ?? resourceGroup().name, 'Microsoft.Network/virtualNetworks/subnets', Subnet.?vNetName ?? 'vnet', Subnet.?subnetName ?? 'default')
      }
      {
        name: 'linos'
        count: 1
        osType: 'Linux'
        vmSize: AgentSize
        mode: 'User'
        nodeTaints: [
          'os=linux:NoSchedule'
        ]
        vnetSubnetID: resourceId(Subnet.?subscriptionId ?? subscription().subscriptionId, Subnet.?resourceGroupName ?? resourceGroup().name, 'Microsoft.Network/virtualNetworks/subnets', Subnet.?vNetName ?? 'vnet', Subnet.?subnetName ?? 'default')
      }
      {
        name: 'winos'
        count: 1
        osType: 'Windows'
        vmSize: AgentSize
        mode: 'User'
        nodeTaints: [
          'os=windows:NoSchedule'
        ]
        windowsProfile: {
          disableOutboundNat: DisableOutboundNat
        }
        vnetSubnetID: resourceId(Subnet.?subscriptionId ?? subscription().subscriptionId, Subnet.?resourceGroupName ?? resourceGroup().name, 'Microsoft.Network/virtualNetworks/subnets', Subnet.?vNetName ?? 'vnet', Subnet.?subnetName ?? 'default')
      }
    ]
    workloadAutoScalerProfile: {
      keda: {
        enabled: true
      }
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    addonProfiles: {
      azurePolicy: {
        enabled: true
      }
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
        }
      }
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: WorkspaceResourceId
          useAADAuth: 'true'
        }
      }
    }
  }
}

module uamiPermissions 'keyvaultAccessPolicy.bicep' = {
  scope: resourceGroup(KeyVault.?subscriptionId ?? subscription().subscriptionId, KeyVault.?resourceGroupName ?? resourceGroup().name)
  name: 'keyvaultAccessPolicy-secrets-${uniqueString(CurrentTime)}'
  params: {
    keyVaultName: KeyVault.name
    accessPolicies: [
      {
        objectId: _aks.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.objectId
        tenantId: tenant().tenantId
        permissions: {
            keys: []
            secrets: [
                'get'
                'list'
            ]
            certificates: []
        }
      }
    ]
  }
}

#disable-next-line BCP081 // Valid API Version
resource _aksMonitoringMsiDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: Location
  kind: 'Linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${_identity.id}': {}
    }
  }
  properties: {
    dataSources: {
      syslog: [
        {
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: SyslogFacilities
          logLevels: SyslogLevels
          name: 'sysLogsDataSource'
        }
      ]
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          streams: Streams
          extensionSettings: {
            dataCollectionSettings: {
              interval: DataCollectionInterval
              namespaceFilteringMode: NamespaceFilteringModeForDataCollection
              namespaces: NamespacesForDataCollection
              enableContainerLogV2: EnableContainerLogV2
            }
          }
          extensionName: 'ContainerInsights'
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: WorkspaceResourceId
          name: 'ciworkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: Streams
        destinations: [
          'ciworkspace'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'ciworkspace'
        ]
      }
    ]
  }
}

#disable-next-line BCP174
resource _aksMonitoringMsiDcra 'Microsoft.ContainerService/managedClusters/providers/dataCollectionRuleAssociations@2022-06-01' = {
  dependsOn: [
    _aks
  ]
  name: '${Name}/microsoft.insights/${dcrName}-assoc'
  properties: {
    description: 'Association of data collection rule. Deleting this association will break the data collection for this AKS Cluster.'
    dataCollectionRuleId: dataCollectionRuleId
  }
}


output aksKubeletIdentity string = _aks.properties.identityProfile.kubeletidentity.objectId
output aksKeyVaultIdentity string = _aks. properties.addonProfiles.azureKeyvaultSecretsProvider.identity.objectId
output nodeResourceGroup string = _aks.properties.nodeResourceGroup
output aksName string = _aks.name

type subnetIdentifier = {
  vNetName: string
  subnetName: string
  resourceGroupName: string?
  subscriptionId: string?
}

type resourceIdentifier = {
  name: string
  resourceGroupName: string?
  subscriptionId: string?
}
