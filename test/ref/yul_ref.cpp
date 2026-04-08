// Tiny reference binary for differential testing.
// Reads Yul from stdin, parses with libyul, prints canonical form to stdout.
// Exit 0 on success, 1 on parse error.

#include <libyul/AsmParser.h>
#include <libyul/AsmPrinter.h>
#include <libyul/AST.h>
#include <libyul/Dialect.h>
#include <libyul/backends/evm/EVMDialect.h>

#include <liblangutil/CharStream.h>
#include <liblangutil/DebugInfoSelection.h>
#include <liblangutil/ErrorReporter.h>
#include <liblangutil/EVMVersion.h>

#include <iostream>
#include <sstream>
#include <string>

using namespace solidity;

int main()
{
	std::ostringstream ss;
	ss << std::cin.rdbuf();
	std::string input = ss.str();

	langutil::EVMVersion evmVersion;
	auto const& dialect = yul::EVMDialect::strictAssemblyForEVM(evmVersion, std::nullopt);

	langutil::ErrorList errors;
	langutil::ErrorReporter reporter(errors);
	langutil::CharStream charStream(input, "stdin");

	yul::Parser parser(reporter, dialect);
	auto ast = parser.parse(charStream);

	if (!ast || !errors.empty())
		return 1;

	yul::AsmPrinter printer(
		dialect,
		std::nullopt,
		langutil::DebugInfoSelection::None()
	);
	std::cout << printer(ast->root()) << std::endl;

	return 0;
}
