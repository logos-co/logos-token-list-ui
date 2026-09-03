cmake_minimum_required(VERSION 3.14)
project(TokenListUiPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

# SOURCES must be listed explicitly — the macro does not glob.
logos_module(
    NAME token_list_ui
    REP_FILE src/token_list_ui.rep
    SOURCES
        src/token_list_ui_backend.h
        src/token_list_ui_backend.cpp
    INCLUDE_DIRS
        src
)
