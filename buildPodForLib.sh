#shell中解析json字符串需要用到jq插件
if command -v jq >/dev/null 2>&1; then
    echo ''
else
    echo '未检测到jq插件，开始用Brew帮您安装'
    command brew install jq
    echo 'jq插件安装完成'
fi

echo "Clean old build"
export PATH=$PATH:/usr/libexec

workdir=$(cd $(dirname $0); pwd)

tempPath="$workdir/libs_temp"
libsPath="$workdir/libs"

rm -rf $tempPath
rm -rf $libsPath

mkdir $tempPath
mkdir $libsPath

podspecPath="$workdir/*.podspec"
workspacePath="$workdir/*.xcworkspace"
projectPath="$workdir/*.xcodeproj"

#注：spectype：main表示主Spec、sub表示子Spec

#-------start--------负责静态库的生成和复制---------------#
function createLib()
{
    spec_type=$1
    spec_originalname=$2
    spec_name="$mainspec_name-$2"

    echo "\n------生成 $spec_name 静态库------\n"

    if [ -e $workspacePath ]
    then
        xcodebuild build -workspace $workspacePath -scheme $spec_name -configuration Release ONLY_ACTIVE_ARCH='NO' ARCHS='x86_64 i386' VALID_ARCHS='x86_64 i386' BUILD_DIR=$tempPath -sdk iphonesimulator -quiet
        xcodebuild build -workspace $workspacePath -scheme $spec_name -configuration Release ONLY_ACTIVE_ARCH='NO' ARCHS='arm64 armv7' VALID_ARCHS='arm64 armv7' BUILD_DIR=$tempPath -sdk iphoneos -quiet
    else
        xcodebuild build -project $projectPath -target $spec_name -configuration Release ONLY_ACTIVE_ARCH='NO' ARCHS='x86_64 i386' VALID_ARCHS='x86_64 i386' BUILD_DIR=$tempPath -sdk iphonesimulator -quiet
        xcodebuild build -project $projectPath -target $spec_name -configuration Release ONLY_ACTIVE_ARCH='NO' ARCHS='arm64 armv7' VALID_ARCHS='arm64 armv7' BUILD_DIR=$tempPath -sdk iphoneos -quiet
    fi

    iphonesimulator="$tempPath/Release-iphonesimulator/lib$spec_name.a"
    iphoneos="$tempPath/Release-iphoneos/lib$spec_name.a"
    dest="$tempPath/Release-iphoneos/lib$spec_name.a"
    if [ ! -e $iphoneos ]
    then
        iphonesimulator="$tempPath/Release-iphonesimulator/$spec_originalname.framework/$spec_originalname"
        iphoneos="$tempPath/Release-iphoneos/$spec_originalname.framework/$spec_originalname"
        dest="$tempPath/Release-iphoneos/$spec_originalname.framework"
    fi

     if [ ! -e $iphoneos ]
     then
          echo "\n------ERROR:在Release模式下，编译 $spec_name 的真机包时失败,请排查解决后再执行------\n"
          exit 1
     fi

     if [ ! -e $iphonesimulator ]
     then
          echo "\n------ERROR:在Release模式下，编译 $spec_name 的模拟器包时失败,请排查解决后再执行------\n"
          exit 1
     fi

     lipo -create "${iphonesimulator}" "${iphoneos}" -o "${iphoneos}"

     path_target="$libsPath"
     if [[ $spec_type == "sub" ]];
     then
        path_target="$libsPath/$spec_originalname"
     fi
     cp -r "${dest}" $path_target

     echo "\n------完成 $spec_name 静态库------\n"
}
#-------end--------负责静态库的生成和复制---------------#

#-------start--------查找指定目录下的指定文件---------------#
function findFileAndCopyIt()
{
    filepath_temp=$1
    targetpath_temp=$2
    fileext_temp=$3

    if [[ $filepath_temp == "[" ]]
    then
        return 1
    fi

    if [[ $filepath_temp == "]" ]]
    then
        return 1
    fi

    #剔除字符串中的双引号或者逗号
    filepath_temp=${filepath_temp//\"/}
    filepath_temp=${filepath_temp//\,/}

    if [[ "$fileext_temp" == "" ]]
    then
        fileext_temp=${filepath_temp##*/}
    fi

    #不包含*，说明是指定的文件，处理方式是直接拷贝，不需要遍历
    #包含**，说明是包含指定的文件目录以及该目录下的所有子目录
    #不包含**And只包含一个，说明是只包含指定的文件目录
    if [[ $filepath_temp != *"*"* ]]
    then
        cp -r $filepath_temp $targetpath_temp
    else
        #从右边开始计算，遇到最后一个*停止，然后截取*左边的所有字符
        subfilepath_temp=${filepath_temp%%'*'*}
        #从右边开始计算，遇到第一个/停止，然后截取/左边的所有字符
        subfilepath_temp=${subfilepath_temp%/*}

        if [[ $filepath_temp == *"**"* ]]
        then
            for hfile in $(find $subfilepath_temp -name "$fileext_temp" |xargs -n1)
            do
                cp -r $hfile $targetpath_temp
            done
        else
            for hfile in $(find $subfilepath_temp \( -name "$fileext_temp" -a -maxdepth 1 \) |xargs -n1)
            do
                cp -r $hfile $targetpath_temp
            done
        fi
    fi
}
#-------end--------查找指定目录下的指定文件---------------#

#-------start--------负责头文件的复制---------------#
function createHeader()
{
    spec_name=$1
    spec_files=${!2}
    spec_type=$3

    if [[ $spec_files != *"["* ]]
    then
        spec_files="\"$spec_files\""
    fi

    path_target="$libsPath"
    if [[ $spec_type == "sub" ]];
    then
        path_target="$libsPath/$spec_name"
    fi

    for filepath in $spec_files
    do
        findFileAndCopyIt $filepath "$path_target" "*.h"
    done
}

function getHeader()
{
    spec_type=$1
    spec_name=$2
    spec_index=$3

    spec_json=$podspec_json
    if [[ $spec_type == "sub" ]];
    then
        spec_json=$subspecs_json
    fi

    spec_files=".source_files"
    if [[ $spec_type == "sub" ]];
    then
        spec_files=".[$spec_index].source_files"
    fi

    source_files=`echo $spec_json | jq -r $spec_files`

    if [[ $source_files != "null" ]]
    then
        createHeader $spec_name source_files[@] $spec_type
    fi

    spec_ios_files=".ios.source_files"
    if [[ $spec_type == "sub" ]];
    then
        spec_ios_files=".[$spec_index].ios.source_files"
    fi

    ios_source_files=`echo $spec_json | jq -r $spec_ios_files`

    if [[ $ios_source_files != "null" ]]
    then
        createHeader $spec_name ios_source_files[@] $spec_type
    fi
}
#-------end--------负责头文件的复制---------------#

#-------start--------负责vendored_frameworks/vendored_libraries的复制---------------#
function createVendored()
{
    spec_name=$1
    spec_files=${!2}
    file_ext=$3
    spec_type=$4

    if [[ $spec_files != *"["* ]]
    then
        spec_files="\"$spec_files\""
    fi

    path_target="$libsPath"
    if [[ $spec_type == "sub" ]];
    then
        path_target="$libsPath/$spec_name"
    fi

    for filepath in $spec_files
    do
        findFileAndCopyIt $filepath "$path_target" "*.$file_ext"
    done
}

function getVendored()
{
    #注：vf和v_fs同时存在时，以v_fs为主；
    #注：v_fs不存在时，v_f的值会补充给v_fs；
    #注：最终解析出来的结果，只以复数的形式存在；
    #注：以下的其他属性也同理

    spec_type=$1
    spec_name=$2
    spec_index=$3

    spec_json=$podspec_json
    if [[ $spec_type == "sub" ]];
    then
        spec_json=$subspecs_json
    fi

    #1复制vendored_frameworks
    spec_files=".vendored_frameworks"
    if [[ $spec_type == "sub" ]];
    then
        spec_files=".[$spec_index].vendored_frameworks"
    fi
    vendored_frameworks=`echo $spec_json | jq -r $spec_files`

    if [[ $vendored_frameworks != "null" ]]
    then
        createVendored $spec_name vendored_frameworks[@] "framework" $spec_type
    fi

    #2复制vendored_libraries
    spec_file_libs=".vendored_libraries"
    if [[ $spec_type == "sub" ]];
    then
        spec_file_libs=".[$spec_index].vendored_libraries"
    fi
    vendored_libs=`echo $spec_json | jq -r $spec_file_libs`

    if [[ $vendored_libs != "null" ]]
    then
        createVendored $spec_name vendored_libs[@] "a" $spec_type
    fi

    #3复制ios_vendored_frameworks
    spec_ios_files=".ios.vendored_frameworks"
    if [[ $spec_type == "sub" ]];
    then
        spec_ios_files=".[$spec_index].ios.vendored_frameworks"
    fi
    ios_vendored_frameworks=`echo $spec_json | jq -r $spec_ios_files`

    if [[ $ios_vendored_frameworks != "null" ]]
    then
        createVendored $spec_name ios_vendored_frameworks[@] "framework" $spec_type
    fi

    #4复制ios_vendored_libraries
    spec_ios_file_libs=".ios.vendored_libraries"
    if [[ $spec_type == "sub" ]];
    then
        spec_ios_file_libs=".[$spec_index].ios.vendored_libraries"
    fi
    ios_vendored_libs=`echo $spec_json | jq -r $spec_ios_file_libs`

    if [[ $ios_vendored_libs != "null" ]]
    then
        createVendored $spec_name ios_vendored_libs[@] "a" $spec_type
    fi
}
#-------end----------负责vendored_frameworks/vendored_libraries的复制---------------#

#-------start--------负责资源文件的复制以及Bundle的生成---------------#

function createResource()
{
    spec_name=$1
    spec_files=${!2}
    spec_type=$3

    if [[ $spec_files != *"["* ]]
    then
        spec_files="\"$spec_files\""
    fi

    path_target="$libsPath"
    if [[ $spec_type == "sub" ]];
    then
        path_target="$libsPath/$spec_name"
    fi

    for path_file in $spec_files
    do
        if [[ $path_file == *"{"* ]]
        then
            echo "\n---error:PodSpec中资源文件的指定的后缀，暂不支持{}写法，请酌情拆分成单个后，再尝试运行此脚本"
            exit 1
        fi

        if [[ $path_file == *"}"* ]]
        then
            echo "\n---error:PodSpec中资源文件的指定的后缀，暂不支持{}写法，请酌情拆分成单个后，再尝试运行此脚本"
            exit 1
        fi

        findFileAndCopyIt $path_file $path_target
    done
}

function createResourceBundle()
{
    spec_name=$1
    bundle_obj=${!2}
    spec_type=$3

    bundle_names=`echo $bundle_obj | jq 'keys'`

    path_prefix="$libsPath"
    if [[ $spec_type == "sub" ]];
    then
        path_prefix="$libsPath/$spec_name"
    fi

    for bundle_name in $bundle_names
    do
        if [ $bundle_name == "[" ]
        then
            continue
        fi

        if [ $bundle_name == "]" ]
        then
            continue
        fi

        #剔除字符串中的双引号或者逗号
        bundle_name=${bundle_name//\"/}
        bundle_name=${bundle_name//\,/}
        bundle_files=`echo $bundle_obj | jq -r ".$bundle_name"`

        #资源文件的bundle名称
        bundle_folderpath="$path_prefix/$bundle_name"

        mkdir $bundle_folderpath

        if [[ $bundle_files != *"["* ]]
        then
            bundle_files="\"$bundle_files\""
        fi

        for bundle_file in $bundle_files
        do
            findFileAndCopyIt $bundle_file $bundle_folderpath
        done

        #资源文件的文件夹名称添加bundle后缀
        mv $bundle_folderpath "$bundle_folderpath.bundle"
    done
}

function getResource()
{
    spec_type=$1
    spec_name=$2
    spec_index=$3

    spec_json=$podspec_json
    if [[ $spec_type == "sub" ]];
    then
        spec_json=$subspecs_json
    fi

    #1复制resource
    spec_files=".resources"
    if [[ $spec_type == "sub" ]];
    then
        spec_files=".[$spec_index].resources"
    fi
    spec_resources=`echo $spec_json | jq -r $spec_files`
    if [[ $spec_resources != "null" ]];
    then
        createResource $spec_name spec_resources[@] $spec_type
    fi

    #2生成Bundle
    spec_files_b=".resource_bundles"
    if [[ $spec_type == "sub" ]];
    then
        spec_files_b=".[$spec_index].resource_bundles"
    fi
    spec_resources_b=`echo $spec_json | jq -r $spec_files_b`
    if [[ $spec_resources_b != "null" ]];
    then
        createResourceBundle $spec_name spec_resources_b[@] $spec_type
    fi

    #3复制ios_resources
    spec_ios_files=".ios.resources"
    if [[ $spec_type == "sub" ]];
    then
        spec_ios_files=".[$spec_index].ios.resources"
    fi
    spec_ios_resources=`echo $spec_json | jq -r $spec_ios_files`
    if [[ $spec_ios_resources != "null" ]];
    then
        createResource $spec_name spec_ios_resources[@] $spec_type
    fi

    #4生成ios_Bundle
    spec_ios_files_b=".ios.resource_bundles"
    if [[ $spec_type == "sub" ]];
    then
        spec_ios_files_b=".[$spec_index].ios.resource_bundles"
    fi
    spec_ios_resources_b=`echo $spec_json | jq -r $spec_ios_files_b`

    if [[ $spec_ios_resources_b != "null" ]];
    then
        createResourceBundle $spec_name spec_ios_resources_b[@] $spec_type
    fi
}
#-------end----------负责资源文件的复制以及Bundle的生成---------------#

#-------start--------获取MainSpec以及SubSpec的产物---------------#
function getMainSpecResult()
{
    #生成静态库
#    createLib "main" $mainspec_name

    #拷贝头文件
    getHeader "main" $mainspec_name

    #拷贝依赖库
    getVendored "main" $mainspec_name

    #拷贝资源文件
    getResource "main" $mainspec_name
}

function getSubSpecResult()
{
    subspec_names=(`echo $subspecs_json | jq -r '.[].name'`)
    for((i=0;i<${#subspec_names[@]};i++));
    do
        #获取subspec的名称
        subspec_name=${subspec_names[i]}

        #cp命令在目录不存在的情况下，不会自动创建，所以额外生成
        mkdir "$libsPath/$subspec_name"

        #生成静态库
        createLib "sub" $subspec_name

        #拷贝头文件
        getHeader "sub" $subspec_name $i

        #拷贝依赖库
        getVendored "sub" $subspec_name $i

        #拷贝资源文件
        getResource "sub" $subspec_name $i
    done
}
#-------end----------获取主Spec的产物---------------#

originaldir=$(pwd)
cd $workdir

echo "\n-----开始构建Lib--------\n"

xcodebuild clean

#把podspec解析成json字符串
podspec_json=$(pod ipc spec $podspecPath)

#获取mainspec的名称
mainspec_name=`echo $podspec_json | jq -r '.name'`

#----复制主Spec
getMainSpecResult

#----复制SubSpec
subspecs_json=`echo $podspec_json | jq -r '.subspecs'`
if [[ $subspecs_json != "null" ]];
then
    getSubSpecResult
fi

echo "\n-----结束构建Lib--------\n"

rm -rf $tempPath

cd $originaldir

exit 0




