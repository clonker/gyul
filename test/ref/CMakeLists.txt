cmake_minimum_required(VERSION 3.16)
project(yul_ref CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SOLIDITY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/solidity")

# Tell solidity's cmake where its source tree is (it normally uses CMAKE_SOURCE_DIR)
set(SOLIDITY_SOURCE_DIR "${SOLIDITY_DIR}")

add_subdirectory(${SOLIDITY_DIR} ${CMAKE_CURRENT_BINARY_DIR}/solidity EXCLUDE_FROM_ALL)

add_executable(yul_ref yul_ref.cpp)
target_link_libraries(yul_ref PRIVATE yul)
