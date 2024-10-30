# Install Python 2.7
sudo apt install python2.7 python-pip
	
# for MacOS:
pyenv install 2.7.18

# Install virtualenv
run pip install virtualenv virtualenvwrapper

# Installing dependencies (from the winner's repo)
virtualenv --python=python2.7 venv

    # If you get the following error
    bash: /usr/bin/virtualenv: No such file or directory

    # Do this
    sudo ln -s /usr/local/python3/bin/virtualenv /usr/bin/virtualenv

    # If you get this error
    RuntimeError: No virtualenv implementation for PathPythonInfo(spec=CPython2.7.18.final.0-64, exe=/usr/bin/python2.7, platform=linux2, version='2.7.18 (default, Aug 23 2022, 17:18:36) \n[GCC 11.2.0]', encoding_fs_io=UTF-8-None)

    # Do this
    pip install -U 'virtualenv<20.0'

# Rest of the instructions
. venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt