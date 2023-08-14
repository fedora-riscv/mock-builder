# Package Build Tools with Mock

This is a guide for using the package build tools with Mock. The package build tools provide a convenient way to build packages using Mock, a tool for building software packages in a clean and isolated environment.

## Usage

To use the package build tools, run the following command:

```
sh build.sh -m <mock_template> [-p|-P] <package|packages_file> [options]
```

## Options

The following options are available:

- `--nocheck`: Do not run the `%check` stage during packaging.
- `--branch (-b) <fedora_branch>`: Checkout the specified branch during packaging.
- `--help (-h)`: Show the help message.
- `--mock-template (-m) <mock_template>`: Use the specified mock template file.
- `--workdir (-w) <workdir>`: Use the specified workdir.
- `--package (-p) <package>`: Build the specified package.
- `--packages-file (-P) <packages_file>`: Build the packages listed in the specified file.
- `--script (-s) <script> <script_param>`: Run the specified script after a successful build. For example: `--script ./test.sh "@@PACKAGE@@"`.
- `--thread (-t) <num_threads>`: Set the number of concurrent threads for processing.
- `--timeout (-T) <timeout>`: Set the timeout for each build.

## Examples

Here are some examples of how to use the package build tools:

1. Build a single package:

```
sh build.sh -m mock_template.cfg -p mypackage
```

2. Build multiple packages listed in a file:

```
sh build.sh -m mock_template.cfg -P packages.txt
```

3. Run a script after a successful build:

```
sh build.sh -m mock_template.cfg -p mypackage --script ./test.sh "@@PACKAGE@@"
```

4. Set the number of concurrent threads for processing:

```
sh build.sh -m mock_template.cfg -P packages.txt --thread 4
```

5. Set the timeout for each build:

```
sh build.sh -m mock_template.cfg -p mypackage --timeout 3600
```

## Help and Support

For further assistance, use the `--help` option to display the help message:

```
sh build.sh --help
```

If you have any questions or need help, please don't hesitate to reach out.

Happy packaging with Mock!