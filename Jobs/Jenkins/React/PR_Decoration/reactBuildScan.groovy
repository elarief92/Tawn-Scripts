def call(Map cfg) {

  def epic                 = cfg.epic
  def branchName           = cfg.branch.toString()
  def lob                  = (cfg.lob ?: "").toString().toUpperCase()
  def buildAgent           = cfg.buildAgent
  def sonarAgent           = cfg.sonarAgent
  def secretScanningAgent  = cfg.secretScanningAgent

  if (!branchName) {
    error("Branch name must be provided")
  }

  if (!['DXP','CXP'].contains(lob)) {
    error("Invalid LOB '${lob}'. Allowed: [DXP, CXP]")
  }

  boolean isPrAnalysis = cfg.sonar.isPrAnalysis ?: false

  String prKey    = cfg.sonar.prKey ?: ''
  String prBranch = cfg.sonar.prBranch ?: ''
  String prBase   = cfg.sonar.prBase ?: branchName

  if (isPrAnalysis) {
    if (!prKey?.trim()) {
      error("PR analysis selected but PR_KEY is empty")
    }

    if (!prBranch?.trim()) {
      error("PR analysis selected but PR_BRANCH is empty")
    }

    if (!prBase?.trim()) {
      error("PR analysis selected but PR_BASE is empty")
    }
  }

  String checkoutBranch = isPrAnalysis ? prBranch : branchName

  echo """
  =========================================================
  SonarQube Analysis Mode
  ---------------------------------------------------------
  PR Analysis     : ${isPrAnalysis}
  Checkout Branch : ${checkoutBranch}
  Branch Base     : ${branchName}
  PR Key          : ${prKey}
  PR Branch       : ${prBranch}
  PR Base         : ${prBase}
  =========================================================
  """

  node(secretScanningAgent) {
    stage("Checkout for Secret Scan (${checkoutBranch})") {
      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${checkoutBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )
    }

    /*
          stage('Trivy DB Update') {
        node(buildAgent) {
          bat """
            E:\\trivy\\trivy.exe fs --download-db-only .
          """
        }
      }

        stage('SCA - Trivy') {
          node(buildAgent) {
            deleteDir()
            unstash 'src'

            int result = bat(
              returnStatus: true,
              script: """
                E:\\trivy\\trivy.exe fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --skip-db-update --format json --output trivy-report.json --exit-code 1 .
              """
            )

            bat """
              if not exist trivy-report.json (
                echo {} > trivy-report.json
              )
            """

            archiveArtifacts artifacts: 'trivy-report.json', fingerprint: true

            script {
              def report = readFile('trivy-report.json').trim()
              if (result != 0) {
                if (report == '{}' || report == '') {
                  error("Trivy scan execution failed. Check console log.")
                } else {
                  error("Trivy found HIGH/CRITICAL vulnerabilities. Check trivy-report.json artifact.")
                }
              }
            }
          }
        }
      */

          /*
          stage('Secret Scan - Gitleaks') {
            int result = bat(
              returnStatus: true,
              script: """
                E:\\gitleaks\\gitleaks.exe detect --no-git --source . --report-format json --report-path gitleaks-report.json --exit-code 1
              """
            )

            bat """
              if not exist gitleaks-report.json (
                echo {} > gitleaks-report.json
              )
            """

            archiveArtifacts artifacts: 'gitleaks-report.json', fingerprint: true

            if (result != 0) {
              error("Gitleaks failed. Check gitleaks-report.json artifact.")
            }
          }
     */
  }

  node(buildAgent) {
    stage("Checkout for Build (${checkoutBranch})") {
      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${checkoutBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )
    }

    getReactArtifactVersion(
      releaseNumber: env.BUILD_NUMBER,
      lob: lob,
      environment: branchName.toUpperCase(),
      packageFile: cfg.app.packageFile
    )

    stage('Set Build Name') {
      currentBuild.displayName = "${epic} ⇔ ${env.ARTIFACT_VERSION}"
      currentBuild.description = "Artifact: ${env.ARTIFACT_VERSION} | Checkout: ${checkoutBranch} | Base: ${branchName} | LOB: ${lob} | Build: #${env.BUILD_NUMBER}"
    }

    stage('Install Dependencies + Build + Test') {
      def nodeHome = tool 'NodeJS'

      env.NODE_HOME = nodeHome
      env.PATH = "${nodeHome};${nodeHome}\\node_modules\\npm\\bin;${env.PATH}"

      bat "${cfg.node.installCmd}"

      if (cfg.node.resetCmd?.trim()) {
        bat "${cfg.node.resetCmd}"
      }

      bat "${cfg.node.buildCmd}"

      bat 'if not exist reports mkdir reports'

      int testResult = bat(
        returnStatus: true,
        script: "${cfg.node.testCoverageCmd}"
      )

      env.UNIT_TEST_RESULT = "${testResult}"

      junit allowEmptyResults: true, testResults: 'reports/junit.xml'

      stash(
        name: 'coverage-report',
        includes: "${cfg.sonar.lcovReportPath},reports/junit.xml",
        allowEmpty: true
      )
    }
  }

  node(sonarAgent) {
    stage("Checkout for Sonar (${checkoutBranch})") {
      deleteDir()

      bbs_checkout(
        branches: [[name: "*/${checkoutBranch}"]],
        credentialsId: cfg.bbs.credentialsId,
        id: cfg.bbs.id,
        projectName: cfg.bbs.projectName,
        repositoryName: cfg.bbs.repositoryName,
        serverId: cfg.bbs.serverId
      )

      if (isPrAnalysis) {
        bat """
          set PATH=C:\\Program Files\\Git\\cmd;%PATH%
          where git
          git --version
          git fetch --all --prune
          git checkout -B "${prBranch}" "dh-sales-v3/${prBranch}"
          git branch -f "${prBase}" "dh-sales-v3/${prBase}"
          git merge-base HEAD "${prBase}"
          git branch
        """
      }

      bat """
        echo Checking Sonar source files...
        echo sonar.sources=${cfg.sonar.sources}
        echo sonar.inclusions=${cfg.sonar.inclusions}
        echo sonar.exclusions=${cfg.sonar.exclusions}

        if not exist "${cfg.sonar.sources}" (
          echo ERROR: sonar.sources path does not exist: ${cfg.sonar.sources}
          exit /b 1
        )

        dir "${cfg.sonar.sources}" /s /b

        dir "${cfg.sonar.sources}" /s /b | findstr /R /I "\\.ts\$ \\.tsx\$"
        if errorlevel 1 (
          echo ERROR: No .ts or .tsx files found under ${cfg.sonar.sources}
          exit /b 1
        )
      """

      unstash 'coverage-report'
    }

    stage('SonarQube Analysis') {
      def nodeHome    = tool 'NodeJS'
      def scannerHome = tool 'sonar-scanner-cli'

      env.NODE_HOME = nodeHome
      env.PATH = "${nodeHome};${nodeHome}\\node_modules\\npm\\bin;${scannerHome}\\bin;${env.PATH}"

      String sonarKey = "${lob}-${cfg.sonar.projectKey}"

      String analysisModeArgs = ""

      if (isPrAnalysis) {
        echo """
        Running SonarQube PR Analysis:
        PR Key    : ${prKey}
        Source    : ${prBranch}
        Target    : ${prBase}
        """

        analysisModeArgs =
          "-Dsonar.pullrequest.key=${prKey} " +
          "-Dsonar.pullrequest.branch=${prBranch} " +
          "-Dsonar.pullrequest.base=${prBase}"
      } else {
        echo "Running SonarQube Branch Analysis: ${branchName}"

        analysisModeArgs = "-Dsonar.branch.name=${branchName}"
      }

      withSonarQubeEnv(cfg.sonar.server) {
        bat """
          "${scannerHome}\\bin\\sonar-scanner.bat" ^
          -Dsonar.projectKey=${sonarKey} ^
          -Dsonar.projectName=${sonarKey} ^
          -Dsonar.projectVersion=${env.ARTIFACT_VERSION} ^
          -Dsonar.sources=${cfg.sonar.sources} ^
          -Dsonar.tests=${cfg.sonar.tests} ^
          -Dsonar.inclusions=${cfg.sonar.inclusions} ^
          -Dsonar.test.inclusions=${cfg.sonar.testInclusions} ^
          -Dsonar.coverage.exclusions=${cfg.sonar.coverageExclusions} ^
          -Dsonar.typescript.tsconfigPaths=${cfg.sonar.tsconfigPaths} ^
          -Dsonar.javascript.lcov.reportPaths=${cfg.sonar.lcovReportPath} ^
          -Dsonar.sourceEncoding=UTF-8 ^
          ${analysisModeArgs} ^
          -Dsonar.exclusions=${cfg.sonar.exclusions} ^
          -Dsonar.scanner.skip.ssl.verification=true ^
          -Dsonar.nodejs.executable="${nodeHome}\\node.exe"
        """
      }
    }

    stage('Quality Gate') {
      timeout(time: 1, unit: 'HOURS') {
        waitForQualityGate abortPipeline: true
      }
    }

    stage('Fail Build If Unit Tests Failed') {
      junit 'reports/junit.xml'
    }
  }

  node(buildAgent) {
    stage('Archive Artifacts') {
      bat 'echo %EPIC% > epic.txt'

      writeFile file: 'artifact_version.txt', text: env.ARTIFACT_VERSION

      archiveArtifacts(
        artifacts: "${cfg.artifacts.path},artifact_version.txt,epic.txt",
        fingerprint: true,
        onlyIfSuccessful: true
      )
    }
  }
}