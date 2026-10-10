# ci.yml
Runs the repository's full verification, `lune run cli/forge check`, on ubuntu-latest for every push (any branch) and every pull request.
The toolchain is pinned via rokit: CompeyDev/setup-rokit@v0.1.2 followed by `rokit install --no-trust-check`.
