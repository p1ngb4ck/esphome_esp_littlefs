
# littlefs_create_partition_image
#
# Create a littlefs image of the specified directory on the host during build and optionally
# have the created image flashed using `idf.py flash`

set(littlefs_py_venv "${CMAKE_CURRENT_BINARY_DIR}/littlefs_py_venv")
set(littlefs_py_requirements "${CMAKE_CURRENT_LIST_DIR}/image-building-requirements.txt")

set_directory_properties(PROPERTIES
    ADDITIONAL_CLEAN_FILES "${littlefs_py_venv}"
)

function(littlefs_create_partition_image partition base_dir)
	set(options FLASH_IN_PROJECT)
	set(multi DEPENDS)
	cmake_parse_arguments(arg "${options}" "" "${multi}" "${ARGN}")

	idf_build_get_property(idf_path IDF_PATH)

	get_filename_component(base_dir_full_path ${base_dir} ABSOLUTE)

	partition_table_get_partition_info(size "--partition-name ${partition}" "size")
	partition_table_get_partition_info(offset "--partition-name ${partition}" "offset")

	if("${size}" AND "${offset}")
		set(image_file ${CMAKE_BINARY_DIR}/${partition}.bin)

		if(CMAKE_HOST_WIN32)
			set(littlefs_py "${littlefs_py_venv}/Scripts/littlefs-python.exe")
			add_custom_command(
					OUTPUT ${littlefs_py_venv}
					COMMAND ${PYTHON} -m venv ${littlefs_py_venv} && ${littlefs_py_venv}/Scripts/pip.exe install -r ${littlefs_py_requirements}
					WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
					DEPENDS ${littlefs_py_requirements}
			)
		else()
			set(littlefs_py "${littlefs_py_venv}/bin/littlefs-python")
			add_custom_command(
					OUTPUT ${littlefs_py_venv}
					COMMAND ${PYTHON} -m venv ${littlefs_py_venv} && ${littlefs_py_venv}/bin/pip install -r ${littlefs_py_requirements}
					WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
					DEPENDS ${littlefs_py_requirements}
			)
		endif()

		# Execute LittleFS image generation; this always executes as there is no way to specify for CMake to watch for
		# contents of the base dir changing.

		add_custom_target(littlefs_${partition}_bin ALL
			COMMAND ${littlefs_py} create ${base_dir_full_path} ${image_file} -v --fs-size=${size} --name-max=${CONFIG_LITTLEFS_OBJ_NAME_LEN} --block-size=4096
			DEPENDS ${arg_DEPENDS} ${littlefs_py_venv}
			)

		set_property(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" APPEND PROPERTY
			ADDITIONAL_MAKE_CLEAN_FILES
			${image_file})

		set(IDF_VER_NO_V "${IDF_VERSION_MAJOR}.${IDF_VERSION_MINOR}")

		if(${IDF_VER_NO_V} VERSION_LESS 5.0)
			message(WARNING "Unsupported/unmaintained/deprecated ESP-IDF version ${IDF_VER}")
		endif()

		idf_component_get_property(main_args esptool_py FLASH_ARGS)
		idf_component_get_property(sub_args esptool_py FLASH_SUB_ARGS)
		esptool_py_flash_target(${partition}-flash "${main_args}" "${sub_args}")
		esptool_py_flash_target_image(${partition}-flash "${partition}" "${offset}" "${image_file}")

		add_dependencies(${partition}-flash littlefs_${partition}_bin)

		if(arg_FLASH_IN_PROJECT)
			esptool_py_flash_target_image(flash "${partition}" "${offset}" "${image_file}")
			add_dependencies(flash littlefs_${partition}_bin)
		endif()

	else()
		set(message "Failed to create littlefs image for partition '${partition}'. "
					"Check project configuration if using the correct partition table file."
		)
		fail_at_build_time(littlefs_${partition}_bin "${message}")
	endif()
endfunction()

# ------------------------------------------------------------------------------------------
# ESPHome pre-fill hand-over (see Kconfig: values come from binary_storage codegen via
# sdkconfig; empty means the feature is off and nothing below runs).
#
# Builds the image for the named partition with FLASH_IN_PROJECT, so it lands in
# flasher_args.json and thereby in every factory/serial flash without any toolchain help.
# Additionally emits <project>.prefill-ota.bin = [64-byte header][app][littlefs image] for
# over-the-air delivery: a stock OTA sender streams that file as-is, and the (patched, an
# esphome external component) OTA receiver recognises the header magic on the first bytes,
# strips it, and routes the stream at the seam in a single pass — app bytes to the OTA
# slot, image bytes straight into this partition. Header layout, big endian:
#   magic "EPF2" (4) | app_size u32 | image_size u32 | label (32, NUL-padded) |
#   image MD5 (16) | reserved zeros (4)
if(CONFIG_ESPHOME_LITTLEFS_PREFILL_PARTITION AND NOT CONFIG_ESPHOME_LITTLEFS_PREFILL_PARTITION STREQUAL "")
	littlefs_create_partition_image(${CONFIG_ESPHOME_LITTLEFS_PREFILL_PARTITION}
		"${CONFIG_ESPHOME_LITTLEFS_PREFILL_DIR}" FLASH_IN_PROJECT)

	idf_build_get_property(project_name PROJECT_NAME)
	idf_build_get_property(build_dir BUILD_DIR)
	set(prefill_image "${CMAKE_BINARY_DIR}/${CONFIG_ESPHOME_LITTLEFS_PREFILL_PARTITION}.bin")
	set(prefill_ota "${build_dir}/${project_name}.prefill-ota.bin")
	idf_build_get_property(python PYTHON)
	add_custom_target(littlefs_prefill_ota_bin ALL
		COMMAND ${python} ${CMAKE_CURRENT_LIST_DIR}/tools/make_prefill_ota.py
			--app ${build_dir}/${project_name}.bin
			--image ${prefill_image}
			--label ${CONFIG_ESPHOME_LITTLEFS_PREFILL_PARTITION}
			--output ${prefill_ota}
		DEPENDS littlefs_${CONFIG_ESPHOME_LITTLEFS_PREFILL_PARTITION}_bin gen_project_binary
		VERBATIM)
endif()
