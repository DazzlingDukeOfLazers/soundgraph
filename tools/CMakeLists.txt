add_executable(sg-validate sg-validate/main.cpp)
target_link_libraries(sg-validate PRIVATE soundgraph::patch_io)

add_executable(sg-render sg-render/main.cpp)
target_link_libraries(sg-render PRIVATE soundgraph::patch_io soundgraph::wav)
