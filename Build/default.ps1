Include ".\helpers.ps1"

properties {
  	$cleanMessage = 'Executed Clean!'
	$testMessage = 'Executed Test!'
  
	$solutionDirectory = (Get-Item $solutionFile).DirectoryName
	$outputDirectory= "$solutionDirectory\.build"
	$temporaryOutputDirectory = "$outputDirectory\temp"
	$webApplicationsOutputDirectory = "$temporaryOutputDirectory\_WA"
	$packagesOutputDirectory = "$outputDirectory\Packages"
	$publishedLibrariesDirectory = "$temporaryOutputDirectory\_PublishedLibraries\"
		
	$buildConfiguration = "Release"
	$buildPlatform = "Any CPU"

	$packagesPath = "$solutionDirectory\packages"
	$7ZipExe = (Find-PackagePath $packagesPath "7-Zip.CommandLine" ) + "\Tools\7za.exe"
	$nugetExe = (Find-PackagePath $packagesPath "NuGet.CommandLine" ) + "\Tools\NuGet.exe"
}

FormatTaskName "`r`n`r`n-------- Executing {0} Task --------"

task default -depends Test

task Init `
  -description "Initialises the build by removing previous artifacts and creating output directories" `
  -requiredVariables outputDirectory, temporaryOutputDirectory `
{
	Assert ("Debug", "Release" -contains $buildConfiguration) `
		   "Invalid build configuration '$buildConfiguration'. Valid values are 'Debug' or 'Release'"

	Assert ("x86", "x64", "Any CPU" -contains $buildPlatform) `
		   "Invalid build platform '$buildPlatform'. Valid values are 'x86', 'x64' or 'Any CPU'"

	# Check that all tools are available
	Write-Host "Checking that all required tools are available"
 
	Assert (Test-Path $7ZipExe) "7-Zip Command Line could not be found"
	Assert (Test-Path $nugetExe) "NuGet Command Line could not be found"

	# Remove previous build results
	if (Test-Path $outputDirectory) 
	{
		Write-Host "Removing output directory located at $outputDirectory"
		Remove-Item $outputDirectory -Force -Recurse
	}
	
	Write-Host "Creating output directory located at $outputDirectory"
	New-Item $outputDirectory -ItemType Directory -Force | Out-Null

	Write-Host "Creating temporary directory located at $temporaryOutputDirectory"
	New-Item $temporaryOutputDirectory -ItemType Directory | Out-Null
}

task Compile `
	-depends Init `
	-description "Compile the code" `
	-requiredVariables solutionFile, buildConfiguration, buildPlatform, temporaryOutputDirectory `
{ 
  	Write-Host "Dotnet Core Restore"
	Exec { 
		dotnet restore "$solutionDirectory\**Solution_File**"
	}

  	Write-Host "Dotnet Core Publishing"	
	Exec { 

		#update version of the project in the project.json
		$projectSettings = (Get-Content "$solutionDirectory\**Path_To_project.json**" -Raw) | ConvertFrom-Json
		
		$projectSettings.version = $version
		$projectSettings | ConvertTo-Json -Depth 4 | Out-File "$solutionDirectory\**Path_To_project.json**"			
		
		#Make sure the directory exists
		Write-Host "Creating temporary directory located at $webApplicationsOutputDirectory"
		New-Item $webApplicationsOutputDirectory -ItemType Directory -Force | Out-Null
		
		$projectSettings.version = $version
		$projectSettings | ConvertTo-Json -Depth 4 | Out-File "$solutionDirectory\**Path_To_project.json**"			

		#Deploying to IIS
		#dnu publish "$solutionDirectory\**Solution_File**" --out "$webApplicationsOutputDirectory\**Package_Name_IIS**" --configuration $buildConfiguration --runtime dnx-clr-win-x86.1.0.0-rc1-update1 --wwwroot "wwwroot" --wwwroot-out "wwwroot" --iis-command "web" --quiet
		dotnet publish "$solutionDirectory\**Solution_File**" -o "$webApplicationsOutputDirectory\**Package_Name_IIS**" --configuration $buildConfiguration 
		
		#Deploying to Azure so we have to set this environment variable to true		
		$env:DNU_PUBLISH_AZURE = 1 
		#dnu publish "$solutionDirectory\**Solution_File**" --out "$webApplicationsOutputDirectory\**Package_Name_Azure**" --configuration $buildConfiguration --runtime dnx-clr-win-x86.1.0.0-rc1-update1 --wwwroot "wwwroot" --wwwroot-out "wwwroot" --iis-command "web" --quiet
		dotnet publish "$solutionDirectory\**Solution_File**" -o "$webApplicationsOutputDirectory\**Package_Name_Azure**" --configuration $buildConfiguration 

		Write-Host "Rename NUSPEC to NUSPEK for Nuget Packaging"	
		#Get-ChildItem -Path "$webApplicationsOutputDirectory\**Package_Name_IIS**" -Recurse -Include *.nuspec | Rename-Item -NewName { $_.Name.replace(".nuspec",".nuspek") }
		Get-ChildItem -Path "$webApplicationsOutputDirectory\**Package_Name_Azure**" -Recurse -Include *.nuspec -Exclude **Package_Name_Azure**.nuspec | Rename-Item -NewName { $_.Name.replace(".nuspec",".nuspek") }
	}	
}

task Package `
	-depends Compile `
	-description "Package application" `
	-requiredVariables buildConfiguration, buildPlatform, temporaryOutputDirectory `
{   	

	# Merge published websites and published applications
	$applications = @(Get-ChildItem $webApplicationsOutputDirectory)
	
	Write-Host "Packaging test as a NuGet package"
	
	if ($applications.Length -gt 0 -and !(Test-Path $webApplicationsOutputDirectory))
	{
		New-Item $webApplicationsOutputDirectory -ItemType Directory | Out-Null
	}

	Write-Output $applications

	foreach($application in $applications)
	{
		$appName = $application.Name.Substring(0, $application.Name.LastIndexOf('.'))
		$nuspecPath = $application.FullName + "\approot\src\" + $appName + "\" + $appName + ".nuspec"

		Write-Host "Looking for nuspec file at $nuspecPath"
		
		if ((Test-Path $nuspecPath) -and ($application.Name -like '*Azure'))
		{
			Write-Host "Packaging $($application.Name) as a NuGet package"

			# Load the nuspec file as XML
			$nuspec = [xml](Get-Content -Path $nuspecPath)

			$metadata = $nuspec.package.metadata

			# Edit the metadata
			$metadata.id = $metadata.id + ".Azure"

			$metadata.version = $version

			#$metadata.version = $metadata.version.Replace("[buildNumber]", $buildNumber)

			#if(! $isMainBranch)
			#{
			#	#$metadata.version = $metadata.version + "-$branchName"
			#}
			
			$metadata.releaseNotes = "Version: $version`r`nBranch Name: $branchName`r`nCommit Hash: $gitCommitHash"

			#set the nuget files path
			$nuspec.package.files.file.src = "\**\*.*"

			# Save the nuspec file
			$nuspec.Save((Get-Item $nuspecPath))

			# package as NuGet package
			exec { & $nugetExe pack $nuspecPath -BasePath $application.FullName -OutputDirectory $application.FullName}
		}
		else
		{
			Write-Host "Packaging $($application.Name) as a zip file"

			$inputDirectory = "$($application.FullName)\*"
			$archivePath = "$($webApplicationsOutputDirectory)\$($application.Name).$version.zip"

			Exec { & $7ZipExe a -r -mx3 $archivePath $inputDirectory }
		}

		#Moving NuGet libraries to the packages directory
		if (Test-Path $webApplicationsOutputDirectory)
		{
			if (!(Test-Path $publishedLibrariesDirectory))
			{
				Mkdir $publishedLibrariesDirectory | Out-Null
			}

			Get-ChildItem -Path $webApplicationsOutputDirectory -Filter "*.nupkg" -Recurse | Move-Item -Destination $publishedLibrariesDirectory
			Get-ChildItem -Path $webApplicationsOutputDirectory -Filter "*.zip" -Recurse | Move-Item -Destination $publishedLibrariesDirectory

			# publish artifacts to Teamcity (We are Assuming that We're using TeamCity)
			$outputFiles = @(Get-ChildItem $publishedLibrariesDirectory)
	
			Write-Host "Publishing artificats to TeamCity"
	
			foreach($file in $outputFiles)
			{
				$fileFormatted = "##teamcity[publishArtifacts '" + $file.FullName + "']"
				Write-Host $fileFormatted
			}	
		}
	}
}

task Clean -description "Remove temporary files" { 
  	Write-Host $cleanMessage
}
 
task Test -depends Compile, Clean -description "Run unit tests" { 
  	Write-Host $testMessage
}