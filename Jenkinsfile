// Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
//
// The generic CI pipeline for the installer template.  It runs the test suite
// on an agent that the parameter chooses, so a site can point it at its own
// builders without changing this file.

pipeline {
    agent none

    parameters {
        string(
            name: 'BUILDER_LABEL',
            defaultValue: 'bsd-builder',
            description: 'The label of the Jenkins agent that runs the test suite.'
        )
    }

    stages {
        stage('Test') {
            agent {
                label params.BUILDER_LABEL
            }
            steps {
                sh 'tests/run-tests.sh'
            }
        }
    }
}
