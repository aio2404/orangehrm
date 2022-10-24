<!--
/**
 * OrangeHRM is a comprehensive Human Resource Management (HRM) System that captures
 * all the essential functionalities required for any enterprise.
 * Copyright (C) 2006 OrangeHRM Inc., http://www.orangehrm.com
 *
 * OrangeHRM is free software; you can redistribute it and/or modify it under the terms of
 * the GNU General Public License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * OrangeHRM is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with this program;
 * if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA  02110-1301, USA
 */
 -->

<template>
  <div class="orangehrm-buzz-post-comment">
    <oxd-divider />
    <div class="orangehrm-buzz-post-comment-add">
      <profile-image :employee="employee"></profile-image>
      <oxd-form class="orangehrm-buzz-post-comment-input">
        <oxd-form-row>
          <oxd-grid-item>
            <oxd-input-field :placeholder="$t('buzz.write_your_comment')" />
          </oxd-grid-item>
        </oxd-form-row>
      </oxd-form>
    </div>
  </div>
</template>

<script>
import ProfileImage from '@/orangehrmBuzzPlugin/components/ProfileImage';

export default {
  name: 'ShowComments',

  components: {
    'profile-image': ProfileImage,
  },

  props: {
    employee: {
      type: Object,
      required: true,
    },
  },
};
</script>

<style lang="scss" scoped>
.orangehrm-buzz-post-comment {
  &-add {
    display: flex;
    align-items: center;
  }
  &-input {
    width: 25rem;
  }
}
</style>
